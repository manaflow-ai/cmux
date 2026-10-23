#!/usr/bin/env python3
"""WebKit page frame cadence bench (perf-lead row 23: every scroll at full refresh).

Each run launches the tagged build the way bench-stalls.py does (no activation, windows on the last
screen, a scratch cmux.json with `browser.defaultEngine: webkit`: a default build opens Settings,
History and Cloud in Chromium, where row 23 changes nothing), from an empty session (the tag's
saved daemon session is removed first: a relaunch otherwise restored the last run's 60 workspaces,
and STRESS grew 65 -> 125 -> ... -> 305), optionally builds the STRESS session
(perf-stress-session.py, in a 1600 x 1000 window: the default 1100 x 720 window had no room for
the 4 x 3 grid, so it built one column), opens the page, then reads the page's own
requestAnimationFrame intervals through `debug.page {action: frames}` while the probe scrolls the
page's scroller a few pixels per frame.

The two rates, inside one build (`debug.low_power_mode` overrides Low Power Mode for the app):

  near60   Low Power Mode on: WebKit's default, the behavior before row 23 (expected on 120 Hz:
           about 16.7 ms, every interval long)
  full     Low Power Mode off: row 23 (expected on 120 Hz: about 8.3 ms, 0 long frames)

Default mode (creation): each launch measures one rate, and sets Low Power Mode before it opens the
page, so the page is made at that rate (the pool makes a new spare on a change). Only the rate a
page is made with is known to hold: on cmux20 (macOS 27, 120 Hz) a shown page switched live to
near60 reported near60 and still rendered at 120 fps, so a live switch cannot be the "before".
Launches alternate the rate (near60, full, near60, ...).

--live: the live switch itself, both directions. One launch opens the page at the first rate,
measures it, switches Low Power Mode with the page on screen, measures, switches back, measures.
Each live leg reports `applied`: whether the page now renders at the rate it reports.

Per leg:
  p50_ms / p95_ms / max_ms   rAF intervals pooled over every window of the leg
  observed_fps               frames per second the page rendered
  expected_fps               the rate's frames per second on this display
  applied                    observed_fps is nearer expected_fps than the other rate's
  long_frames                intervals over 1.5 display refreshes (each one a refresh not rendered)
  scrolled_px                how far the scroller really moved over the windows

A leg counts only when the page reports engine webkit, the reply has the display's rate, the rate
asked for, every window really scrolled (Settings' document never scrolls: the default selector
for cmux.settings is its `.content` scroller), and, at near60, the page really renders near 60: a
page that reports near60 and renders at the full rate measures nothing of the base behavior (a
full-rate leg that renders slower is a result, its long frames count). In --live mode a leg that
did not apply is reported, not refused: that is what --live measures. A STRESS session that is not
the standard shape (60 workspaces, 12 or more measured panes, no refusals) is reported with every
leg (`stress_standard: false`). On a 60 Hz display both rates read the same: judge row 23 on a
120 Hz host. Several tags (different builds) run interleaved, so machine load affects them alike:

  scripts/cmux-next/bench-page-cadence.py --tag mytag --runs 6 [--stress] [--live] [--json out.json]

Kills only the apps it launched. Exit 1 when a tag and leg has no valid run.
"""
import argparse
import importlib.util
import json
import math
import os
import shutil
import statistics
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))

# The element each page scrolls. A page missing here scrolls its document (`document.scrollingElement`).
DEFAULT_SELECTORS = {"cmux.settings": ".content"}

# The Low Power Mode override each rate needs (the page's `render_rate` must then read the rate).
RATES = {"near60": True, "full": False}

# The STRESS window (perf-stress-session.py lays its 4 x 3 grid out for 1600 x 1000).
STRESS_WINDOW_FRAME = "0,0,1600,1000"

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


def expected_fps(rate, display_fps):
    """The frames per second `rate` renders at on a display whose highest rate is `display_fps`."""
    if rate == "full" or display_fps <= 60:
        return display_fps
    return display_fps / (display_fps // 60)  # WebKit's divisor nearest 60 at or above it


def measure_rate(run, opts, rate, selector, live=False):
    """The pooled metrics of `opts.windows` frames windows at `rate` (Low Power Mode already set);
    WindowError when invalid."""
    params = {"page": opts.page, "action": "frames", "window_ms": opts.window_ms, "scroll_px": opts.scroll_px}
    if selector:
        params["selector"] = selector
    counters = {"retries": 0}
    # The first window holds the open or the switch (a live switch re-shows the page under a
    # snapshot and hides it 33 ms), not scroll work, so it is read and dropped.
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
    if not intervals:
        raise WindowError("the page rendered no frames in the windows (hidden or covered)")
    limit = 1.5 * 1000 / fps
    observed = len(intervals) * 1000 / sum(intervals)
    expected = expected_fps(rate, fps)
    other = expected_fps("full" if rate == "near60" else "near60", fps)
    applied = expected == other or abs(observed - expected) < abs(observed - other)
    metrics = {
        "rate": rate, "engine": first.get("engine"), "render_rate": first.get("render_rate"), "display_fps": fps,
        "frames": len(intervals), "scrolled_px": round(scrolled, 1), "retries": counters["retries"],
        "observed_fps": round(observed, 1), "expected_fps": round(expected, 1), "applied": applied,
        "p50_ms": round(nearest_rank(intervals, 0.5), 2),
        "p95_ms": round(nearest_rank(intervals, 0.95), 2),
        "max_ms": round(max(intervals), 2),
        "long_frames": sum(1 for v in intervals if v > limit),
    }
    # The base behavior must really be the base: a page that reports near60 and renders at the full
    # rate measured the full rate (044d6e0b21c on cmux20: a live switch to near60 did not apply).
    if rate == "near60" and not applied and not live:
        raise WindowError(f"the page reports near60 but renders at {observed:.1f} fps (near60 is {expected:.1f} "
                          f"on {fps:g} Hz): the rate did not apply, this leg is not the base behavior")
    return metrics


def fresh_session(tag):
    """Removes the tag's saved daemon session, so the launch starts with one empty workspace."""
    shutil.rmtree(os.path.expanduser(f"~/Library/Application Support/cmux/tags/{tag}/tui"), ignore_errors=True)


def stress_standard(summary):
    """Whether STRESS has the standard shape (perf-lead brief): 60 workspaces, 12 measured panes."""
    return (summary.get("workspaces") == 60 and (summary.get("measured_panes") or 0) >= 12
            and not summary.get("refusals"))


def one_run(tag, opts, legs):
    """One launch of `tag`. `legs` is a list of (label, rate, live): the first sets Low Power Mode
    before the page opens (made at that rate), each later one switches it with the page on screen
    when `live`. Returns {label: metrics or {error}}."""
    scratch = tempfile.mkdtemp(prefix=f"bench-page-cadence-{tag}-")
    with open(os.path.join(scratch, "cmux.json"), "w") as config:
        # From launch, so the pool's spare (Settings, History and Cloud open on it) is WebKit too.
        json.dump({"browser": {"defaultEngine": "webkit"}}, config)
    extra_env = {"CMUX_NEXT_TEST_WINDOW_FRAME": STRESS_WINDOW_FRAME} if opts.stress else {}
    fresh_session(tag)
    run = bench.Run(tag, opts.threshold_ms, scratch, extra_env=extra_env)
    run.launch()
    session = {"session": "STRESS" if opts.stress else "light"}

    def failed(message):
        return {label: {"rate": rate, **session, "error": message} for label, rate, _ in legs}

    try:
        run.wait_launch_settled()
        if opts.stress:
            module = load("perf_stress_session", "perf-stress-session.py")
            stress = module.Stress(module.socket_rpc(run.socket)).build()
            print(f"STRESS-SESSION {json.dumps(stress)}", flush=True)
            session["stress_standard"] = stress_standard(stress)
            session["stress_shape"] = {key: stress.get(key) for key in ("workspaces", "measured_panes", "measured_columns",
                                                                         "measured_tabs", "busy_terminals", "refusals")}
            if not session["stress_standard"]:
                print(f"STRESS is not the standard shape (60 workspaces, 12 panes, no refusals): {session['stress_shape']}",
                      flush=True)
        # The first leg's rate before the page exists: the page (or the spare the pool makes after
        # the change) is made at it.
        try:
            set_low_power(run, RATES[legs[0][1]])
        except WindowError as error:
            return failed(str(error))
        run.call("action.run", {"action": opts.open_action, "focus": True})
        if not poll(lambda: page_shown(run, opts.page)):
            return failed(f"{opts.page} never painted")
        time.sleep(1.0)  # let the page's first frames and pool refills finish before the windows
        selector = opts.selector or DEFAULT_SELECTORS.get(opts.page)
        results = {}
        for index, (label, rate, live) in enumerate(legs):
            try:
                if index > 0:
                    set_low_power(run, RATES[rate])
                metrics = measure_rate(run, opts, rate, selector, live=live)
            except WindowError as error:
                metrics = {"rate": rate, "error": str(error)}
            metrics.update(session)
            metrics["leg"] = label
            if "error" not in metrics and metrics["engine"] != "webkit":
                metrics["error"] = "the page is not WebKit: this run measures nothing for row 23"
            results[label] = metrics
        return results
    finally:
        bench.stop_tag(tag, run.pid)


def legs_for(index, opts):
    """The legs of launch `index`: creation mode measures one rate per launch, alternating; --live
    measures the first rate, a live switch to the other, and a live switch back."""
    rates = opts.rate or ["near60", "full"]
    if opts.live:
        first, second = (rates[0], rates[-1]) if index % 2 == 0 else (rates[-1], rates[0])
        return [(f"made {first}", first, False), (f"live {first}->{second}", second, True),
                (f"live {second}->{first}", first, True)]
    rate = rates[index % len(rates)]
    return [(rate, rate, False)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", action="append", required=True)
    parser.add_argument("--runs", type=int, default=6,
                        help="launches per tag (creation mode: one rate each, so 6 gives 3 per rate)")
    parser.add_argument("--rate", action="append", choices=sorted(RATES),
                        help="the rates to measure (default both: near60 is the base behavior, full is row 23)")
    parser.add_argument("--live", action="store_true",
                        help="measure the live Low Power Mode switch with the page on screen, both directions")
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
    if opts.live and len(set(opts.rate or RATES)) < 2:
        parser.error("--live switches between two rates: pass both or neither --rate")
    if opts.stress and opts.window_ms > STRESS_WINDOW_MS:
        print(f"--stress: window_ms {opts.window_ms:g} -> {STRESS_WINDOW_MS} (inside the 2 s control deadline)", flush=True)
        opts.window_ms = STRESS_WINDOW_MS
    print(f"load average {os.getloadavg()}", flush=True)
    results = {tag: {} for tag in opts.tag}
    for index in range(opts.runs):
        legs = legs_for(index, opts)
        for tag in opts.tag:  # interleaved, so machine load affects every tag alike
            for label, metrics in one_run(tag, opts, legs).items():
                results[tag].setdefault(label, []).append(metrics)
                print(f"run {index + 1} {tag} {label}: {json.dumps(metrics)}", flush=True)
    failed = False
    session = "STRESS" if opts.stress else "light"
    for tag, by_leg in results.items():
        for label, runs in sorted(by_leg.items()):
            valid = [r for r in runs if "error" not in r]
            failed = failed or not valid
            print(f"\n{tag} {label} ({opts.page}, {session}): {len(valid)} of {len(runs)} runs valid")
            if not valid:
                continue
            fps = sorted({r["display_fps"] for r in valid})
            print(f"  render_rate {sorted({r['render_rate'] for r in valid})}  display_fps {fps}"
                  f"  applied {sum(1 for r in valid if r['applied'])} of {len(valid)}"
                  f"  retries {sum(r['retries'] for r in valid)}")
            if opts.stress and not all(r.get("stress_standard") for r in valid):
                print("  STRESS not the standard shape in some runs: see stress_shape in the run lines")
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
