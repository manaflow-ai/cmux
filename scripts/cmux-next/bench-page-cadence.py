#!/usr/bin/env python3
"""WebKit page frame cadence bench (perf-lead row 23: every scroll at full refresh).

Each run launches the tagged build the way bench-stalls.py does (no activation, windows on the last
screen, a scratch cmux.json with `browser.defaultEngine: webkit`: a default build opens Settings,
History and Cloud in Chromium, where row 23 changes nothing), optionally builds the STRESS session
(perf-stress-session.py; its Chromium tabs name their engine, so STRESS keeps its shape), opens
the page, then reads the page's own requestAnimationFrame intervals through
`debug.page {action: frames}` while the probe scrolls the page's scroller a few pixels per frame.

The before/after comparison runs inside one build, so it needs no build without the probe (a build
before the frames probe answers `unknown action`). `debug.low_power_mode` overrides Low Power Mode
for the app: on, every `.display` page renders near 60 fps (WebKit's default, the behavior before
row 23); off, it renders at the display's full rate. Each run measures both rates in the same app,
alternating which goes first, and every reply must report the rate asked for:

  near60   Low Power Mode override on: the base behavior (expected on 120 Hz: about 16.7 ms, every
           interval long)
  full     Low Power Mode override off: row 23 (expected on 120 Hz: about 8.3 ms, 0 long frames)

Per rate:
  p50_ms / p95_ms / max_ms   rAF intervals pooled over every window of the run
  observed_fps               frames per second the page rendered
  long_frames                intervals over 1.5 display refreshes (each one a refresh not rendered)
  scrolled_px                how far the scroller really moved over the windows

A run counts only when the page reports engine webkit, the reply has the display's rate, the rate
the run asked for, and (with --scroll-px > 0) every window really scrolled: Settings' document
never scrolls (`overflow: hidden`), so the default selector for cmux.settings is its `.content`
scroller. On a 60 Hz display both rates read the same: judge row 23 on a 120 Hz host. Several tags
(different builds) run interleaved, so machine load affects them alike:

  scripts/cmux-next/bench-page-cadence.py --tag mytag --runs 3 [--stress] [--json out.json]

Kills only the apps it launched. Exit 1 when a tag and rate has no valid run.
"""
import argparse
import importlib.util
import json
import math
import os
import statistics
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))

# The element each page scrolls. A page missing here scrolls its document (`document.scrollingElement`).
DEFAULT_SELECTORS = {"cmux.settings": ".content"}

# The Low Power Mode override each rate needs (the page's `render_rate` must then read the rate).
RATES = {"near60": True, "full": False}

# A frames window is one control call under the router's 2 s deadline; STRESS can delay the main
# thread around the page script, so its windows stay at or under this.
STRESS_WINDOW_MS = 1000


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    argv = sys.argv
    sys.argv = argv[:1]
    try:
        spec.loader.exec_module(module)
    finally:
        sys.argv = argv
    return module


bench = load("bench_stalls", "bench-stalls.py")


def poll(predicate, seconds=20, step=0.05):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # bench poll, not app code
    return None


def page_shown(run, page):
    state = run.result("debug.page", {"page": page})
    if isinstance(state, dict) and "error" not in state and state.get("painted"):
        return state
    return None


def nearest_rank(values, fraction):
    ordered = sorted(values)
    rank = max(1, min(len(ordered), math.ceil(fraction * len(ordered))))
    return ordered[rank - 1]


class WindowError(Exception):
    pass


def frames_window(run, params, counters):
    """One frames window: its reply, retried once when the control call timed out."""
    for attempt in range(2):
        message = run.call("debug.page", params)
        error = message.get("error") if isinstance(message, dict) else {"message": repr(message)}
        if error:
            code = error.get("code") if isinstance(error, dict) else None
            if code == "timeout" and attempt == 0:
                counters["retries"] += 1
                continue
            raise WindowError(f"frames: {error}")
        reply = message.get("result")
        if not isinstance(reply, dict) or not reply:
            raise WindowError(f"frames: empty reply {message}")
        if "error" in reply:
            raise WindowError(f"frames: {reply['error']}")
        return reply
    raise WindowError("frames: unreachable")


def set_low_power(run, enabled):
    reply = run.result("debug.low_power_mode", {"enabled": enabled})
    if reply.get("enabled") is not enabled:
        raise WindowError(f"debug.low_power_mode did not take enabled={enabled}: {reply}")


def measure_rate(run, opts, rate, selector):
    """The pooled metrics of `opts.windows` frames windows at `rate`; WindowError when invalid."""
    set_low_power(run, RATES[rate])
    params = {"page": opts.page, "action": "frames", "window_ms": opts.window_ms, "scroll_px": opts.scroll_px}
    if selector:
        params["selector"] = selector
    counters = {"retries": 0}
    # The rate change re-shows the page (snapshot cover, a 33 ms hide): that window holds the
    # toggle, not scroll work, so it is read and dropped.
    frames_window(run, params, counters)
    intervals, scrolled, replies = [], 0.0, []
    for _ in range(opts.windows):
        reply = frames_window(run, params, counters)
        replies.append(reply)
        if reply.get("render_rate") != rate:
            raise WindowError(f"asked for {rate}, the page reports render_rate {reply.get('render_rate')}")
        window_scrolled = reply.get("scrolled_px") or 0
        if opts.scroll_px > 0 and window_scrolled <= 0:
            raise WindowError(f"the scroller ({selector or 'document'}) did not move: the window measured an idle page")
        scrolled += window_scrolled
        intervals.extend(v for v in reply.get("intervals_ms") or [] if isinstance(v, (int, float)))
    first = replies[0]
    fps = first.get("display_fps")
    if not isinstance(fps, (int, float)) or fps <= 0:
        raise WindowError("no display_fps (the page has no window or screen): drops cannot be judged")
    limit = 1.5 * 1000 / fps
    return {
        "rate": rate, "engine": first.get("engine"), "render_rate": first.get("render_rate"), "display_fps": fps,
        "frames": len(intervals), "scrolled_px": round(scrolled, 1), "retries": counters["retries"],
        "observed_fps": round(len(intervals) * 1000 / sum(intervals), 1) if intervals else None,
        "p50_ms": round(nearest_rank(intervals, 0.5), 2) if intervals else None,
        "p95_ms": round(nearest_rank(intervals, 0.95), 2) if intervals else None,
        "max_ms": round(max(intervals), 2) if intervals else None,
        "long_frames": sum(1 for v in intervals if v > limit),
    }


def one_run(tag, opts, rates):
    """One launch of `tag`: {rate: metrics or {error}} for each rate, in the order given."""
    scratch = tempfile.mkdtemp(prefix=f"bench-page-cadence-{tag}-")
    with open(os.path.join(scratch, "cmux.json"), "w") as config:
        # From launch, so the pool's spare (Settings, History and Cloud open on it) is WebKit too.
        json.dump({"browser": {"defaultEngine": "webkit"}}, config)
    run = bench.Run(tag, opts.threshold_ms, scratch)
    run.launch()
    try:
        run.wait_launch_settled()
        session = "light"
        if opts.stress:
            module = load("perf_stress_session", "perf-stress-session.py")
            stress = module.Stress(module.socket_rpc(run.socket)).build()
            print(f"STRESS-SESSION {json.dumps(stress)}", flush=True)
            session = "STRESS"
        run.call("action.run", {"action": opts.open_action, "focus": True})
        if not poll(lambda: page_shown(run, opts.page)):
            return {rate: {"rate": rate, "session": session, "error": f"{opts.page} never painted"} for rate in rates}
        time.sleep(1.0)  # let the page's first frames and pool refills finish before the windows
        selector = opts.selector or DEFAULT_SELECTORS.get(opts.page)
        results = {}
        for rate in rates:
            try:
                metrics = measure_rate(run, opts, rate, selector)
            except WindowError as error:
                metrics = {"rate": rate, "error": str(error)}
            metrics["session"] = session
            if "error" not in metrics and metrics["engine"] != "webkit":
                metrics["error"] = "the page is not WebKit: this run measures nothing for row 23"
            results[rate] = metrics
        return results
    finally:
        bench.stop_tag(tag, run.pid)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", action="append", required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--rate", action="append", choices=sorted(RATES),
                        help="the rates to measure (default both: near60 is the base behavior, full is row 23)")
    parser.add_argument("--page", default="cmux.settings")
    parser.add_argument("--open-action", default="openSettings")
    parser.add_argument("--selector", help="the CSS selector of the scroller (default: the page's known scroller, "
                                           "else the document's)")
    parser.add_argument("--scroll-px", type=float, default=4)
    parser.add_argument("--window-ms", type=float, default=1000)
    parser.add_argument("--windows", type=int, default=5)
    parser.add_argument("--stress", action="store_true", help="build the STRESS session before opening the page")
    parser.add_argument("--threshold-ms", type=int, default=8)
    parser.add_argument("--json")
    opts = parser.parse_args()
    if opts.stress and opts.window_ms > STRESS_WINDOW_MS:
        print(f"--stress: window_ms {opts.window_ms:g} -> {STRESS_WINDOW_MS} (inside the 2 s control deadline)", flush=True)
        opts.window_ms = STRESS_WINDOW_MS
    rates = opts.rate or ["near60", "full"]
    print(f"load average {os.getloadavg()}", flush=True)
    results = {tag: {rate: [] for rate in rates} for tag in opts.tag}
    for index in range(opts.runs):
        order = rates if index % 2 == 0 else list(reversed(rates))  # neither rate always runs first
        for tag in opts.tag:  # interleaved, so machine load affects every tag alike
            for rate, metrics in one_run(tag, opts, order).items():
                results[tag][rate].append(metrics)
                print(f"run {index + 1} {tag} {rate}: {json.dumps(metrics)}", flush=True)
    failed = False
    session = "STRESS" if opts.stress else "light"
    for tag, by_rate in results.items():
        for rate, runs in by_rate.items():
            valid = [r for r in runs if "error" not in r]
            failed = failed or not valid
            print(f"\n{tag} {rate} ({opts.page}, {session}): {len(valid)} of {len(runs)} runs valid")
            if not valid:
                continue
            fps = sorted({r["display_fps"] for r in valid})
            print(f"  render_rate {sorted({r['render_rate'] for r in valid})}  display_fps {fps}"
                  f"  retries {sum(r['retries'] for r in valid)}")
            if max(fps) <= 60:
                print("  display at 60 Hz or less: near60 and full render alike here; judge row 23 on 120 Hz")
            for key in ("p50_ms", "p95_ms", "max_ms", "observed_fps", "long_frames", "scrolled_px"):
                values = [r[key] for r in valid if isinstance(r.get(key), (int, float))]
                if values:
                    print(f"  {key:14} median {statistics.median(values):8.2f}  min {min(values):8.2f}  max {max(values):8.2f}")
    if opts.json:
        with open(opts.json, "w") as out:
            json.dump(results, out, indent=1)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
