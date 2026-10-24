#!/usr/bin/env python3
"""WebKit page frame cadence bench (perf-lead row 23: every scroll at the display's full refresh).

What it guards, with the page on screen in one launch:

  full        Low Power Mode off: a WebKit page renders at the display's rate (120 fps on 120 Hz,
              about 8.3 ms per frame, no long frames). Before row 23 every page but the agent chat
              kept WebKit's default, the display-rate divisor nearest 60 fps: 60 fps on 120 Hz.
  low-power   macOS Low Power Mode switched on with the page on screen: WebKit halves the page's rate
              by itself (its LowPowerMode throttling reason, live): 60 fps on 120 Hz. Before, cmux also
              set the near-60 preference in Low Power Mode, so a page made then rendered at 30 fps,
              and the live switch (write the preference, hide and re-show the page) did not reach a
              shown page at all (cmux20, macOS 27: 120 fps after the switch to near60).
  full-again  Low Power Mode switched off again with the page on screen: back to the display's rate.

Each leg reads the page's own requestAnimationFrame intervals through `debug.page {action: frames}`
while the probe scrolls the page's scroller a few pixels per frame (main-thread scroll work). A leg
passes when the observed rate is nearer the rate it expects than any other rate WebKit could give
(display, display/2, display/4), so it is red on a build without the fix and green with it.

Low Power Mode is macOS's own (`sudo -n pmset -a lowpowermode 0|1`): WebKit's web processes follow
macOS, not cmux's `debug.low_power_mode` override, so only the real switch measures the product.
The bench restores the value it found. Without a passwordless sudo for pmset it measures `full`
only when `--no-low-power` says so; otherwise the Low Power Mode legs fail (they did not run).

The launch (scripts/cmux-next/bench_launch.py, P12) keeps the default engine, Chromium, so the
STRESS session (perf-stress-session.py, `--stress`) has its real Chromium pages; then
`browser.defaultEngine` is set to WebKit live and the page is opened, so the measured page is WebKit
(each reply's `engine` must say so). A display at 60 Hz or less cannot tell the rates apart: the
bench refuses it. Light and STRESS are separate launches:

  scripts/cmux-next/bench-page-cadence.py --app "/path/cmux DEV <tag>.app" [--stress] [--runs 3] [--json out.json]

Prints one `PAGE-CADENCE {json}` line per leg and run, with host, macOS, display_fps and, for
STRESS, the `STRESS-SESSION` shape. Exit 0 when every leg of every run passed; 1 when one did not
match its rate (or did not run); 2 when the run could not measure (no WebKit page, 60 Hz display,
no frames).
"""
import argparse
import importlib.util
import json
import math
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, host_facts  # noqa: E402

# The element each page scrolls. A page missing here scrolls its document (`document.scrollingElement`).
DEFAULT_SELECTORS = {"cmux.settings": ".content"}

# A frames window is one control call under the router's 2 s deadline.
WINDOW_MS = 1000

# Each leg: (label, Low Power Mode, the divisor of the display rate WebKit renders the page at).
LEGS = [("full", False, 1), ("low-power", True, 2), ("full-again", False, 1)]
# Every rate WebKit can give a page on a display: full, half (near 60 on 120 Hz, or Low Power Mode),
# and a quarter (near 60 and Low Power Mode together, the behavior before row 23 in Low Power Mode).
DIVISORS = (1, 2, 4)


class Unmeasurable(Exception):
    """The run cannot judge a cadence (exit 2)."""


def load_stress():
    path = os.path.join(HERE, "perf-stress-session.py")
    spec = importlib.util.spec_from_file_location("perf_stress_session", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def nearest_rank(values, fraction):
    ordered = sorted(values)
    rank = max(1, min(len(ordered), math.ceil(fraction * len(ordered))))
    return ordered[rank - 1]


def system_low_power():
    out = subprocess.run(["pmset", "-g"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "lowpowermode":
            return parts[1] == "1"
    return None


def set_system_low_power(enabled):
    """Switches macOS Low Power Mode; False when this account cannot (no passwordless sudo for pmset)."""
    done = subprocess.run(["sudo", "-n", "pmset", "-a", "lowpowermode", "1" if enabled else "0"],
                          capture_output=True, text=True)
    return done.returncode == 0 and system_low_power() == enabled


def wait_for(predicate, seconds, step=0.1):
    end = time.monotonic() + seconds
    while time.monotonic() < end:  # bench: bounded wait for the app's reply
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def frames_window(app, params):
    reply = app.rpc("debug.page", params, timeout=10)
    if not isinstance(reply, dict) or "error" in reply:
        raise Unmeasurable(f"debug.page frames: {reply}")
    return reply


def measure(app, opts, selector, low_power, divisor):
    params = {"page": opts.page, "action": "frames", "window_ms": WINDOW_MS, "scroll_px": opts.scroll_px}
    if selector:
        params["selector"] = selector
    # The first window holds the switch (WebKit adjusts the page's rate on its next activity), not
    # the steady cadence: read and dropped.
    frames_window(app, params)
    intervals, scrolled, first = [], 0.0, None
    for _ in range(opts.windows):
        reply = frames_window(app, params)
        first = first or reply
        if reply.get("engine") != "webkit":
            raise Unmeasurable(f"the page shows in {reply.get('engine')}, not WebKit: this measures nothing for row 23")
        if reply.get("low_power_mode") is not low_power:
            raise Unmeasurable(f"the app reports low_power_mode {reply.get('low_power_mode')}, the leg needs {low_power}")
        if (reply.get("scrolled_px") or 0) <= 0:
            raise Unmeasurable(f"the scroller ({selector or 'document'}) did not move: the window measured an idle page")
        scrolled += reply["scrolled_px"]
        intervals.extend(v for v in reply.get("intervals_ms") or [] if isinstance(v, (int, float)))
    display = first.get("display_fps")
    if not isinstance(display, (int, float)) or display <= 60:
        raise Unmeasurable(f"display_fps {display}: at 60 Hz or less the rates cannot be told apart; use a 120 Hz host")
    if not intervals:
        raise Unmeasurable("the page rendered no frames (hidden or covered)")
    observed = len(intervals) * 1000 / sum(intervals)
    nearest = min(DIVISORS, key=lambda d: abs(observed - display / d))
    return {
        "render_rate": first.get("render_rate"), "display_fps": display, "frames": len(intervals),
        "observed_fps": round(observed, 1), "expected_fps": round(display / divisor, 1),
        "passed": nearest == divisor, "scrolled_px": round(scrolled, 1),
        "p50_ms": round(nearest_rank(intervals, 0.5), 2), "p95_ms": round(nearest_rank(intervals, 0.95), 2),
        "max_ms": round(max(intervals), 2), "long_frames": sum(1 for v in intervals if v > 1.5 * 1000 / display),
    }


def one_run(opts, index, facts):
    app = BenchApp(opts.app, out=opts.out, log_name=f"app-run{index}.log")
    results = []
    try:
        app.launch(settle=1.0)
        session = {"session": "STRESS" if opts.stress else "light"}
        if opts.stress:
            stress = load_stress()
            summary = stress.Stress(app.rpc).build()
            print(f"STRESS-SESSION {json.dumps(summary)}", flush=True)
            session["stress"] = {key: summary.get(key) for key in ("workspaces", "measured_panes", "shown_columns",
                                                                   "measured_tabs", "busy_terminals", "refusals")}
        # The measured page in WebKit; the STRESS session's Chromium pages stay Chromium.
        engine = app.rpc("settings.set", {"path": "browser.defaultEngine", "value": "webkit"})
        if isinstance(engine, dict) and engine.get("error"):
            raise Unmeasurable(f"settings.set browser.defaultEngine: {engine['error']}")
        app.rpc("action.run", {"action": opts.open_action, "focus": True})
        shown = wait_for(lambda: (lambda s: s if isinstance(s, dict) and s.get("painted") else None)(
            app.rpc("debug.page", {"page": opts.page})), 30)
        if not shown:
            raise Unmeasurable(f"{opts.page} never painted")
        time.sleep(1.0)  # bench: the page's first frames and the pool's refill end before the windows
        selector = opts.selector or DEFAULT_SELECTORS.get(opts.page)
        legs = LEGS[:1] if opts.no_low_power else LEGS
        for label, low_power, divisor in legs:
            row = {"leg": label, "run": index, **facts, **session, "page": opts.page}
            if low_power != system_low_power() and not set_system_low_power(low_power):
                row.update(error=f"cannot switch macOS Low Power Mode to {low_power} (sudo -n pmset); "
                                 "this leg did not run")
            else:
                # The app (and every web process) hears NSProcessInfoPowerStateDidChange.
                if not wait_for(lambda: (app.rpc("debug.low_power_mode") or {}).get("system") is low_power, 10):
                    row.update(error=f"the app never saw Low Power Mode {low_power}")
                else:
                    row.update(measure(app, opts, selector, low_power, divisor))
            results.append(row)
            print(f"PAGE-CADENCE {json.dumps(row)}", flush=True)
        return results
    finally:
        app.stop()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="the tagged cmux DEV .app")
    parser.add_argument("--out", help="folder for the app logs")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--stress", action="store_true", help="build the STRESS session before opening the page")
    parser.add_argument("--page", default="cmux.settings")
    parser.add_argument("--open-action", default="openSettings")
    parser.add_argument("--selector", help="the scroller's CSS selector (default: the page's known scroller, else the document's)")
    parser.add_argument("--scroll-px", type=float, default=4)
    parser.add_argument("--windows", type=int, default=5)
    parser.add_argument("--no-low-power", action="store_true",
                        help="measure the full-rate leg only (a host without passwordless sudo for pmset)")
    parser.add_argument("--json")
    opts = parser.parse_args()
    facts = host_facts()
    found = system_low_power()
    print(f"host {facts} low_power_mode {found} load average {os.getloadavg()}", flush=True)
    rows, unmeasurable = [], None
    try:
        for index in range(1, opts.runs + 1):
            try:
                rows.extend(one_run(opts, index, facts))
            except Unmeasurable as error:
                unmeasurable = str(error)
                print(f"PAGE-CADENCE {json.dumps({'run': index, **facts, 'error': unmeasurable})}", flush=True)
                break
    finally:
        if found is not None and system_low_power() != found:
            set_system_low_power(found)
    for label in sorted({r["leg"] for r in rows}):
        legs = [r for r in rows if r["leg"] == label]
        valid = [r for r in legs if "error" not in r]
        print(f"\n{label}: {sum(1 for r in valid if r['passed'])} of {len(legs)} runs at the expected rate")
        for key in ("observed_fps", "expected_fps", "p50_ms", "p95_ms", "max_ms", "long_frames"):
            values = [r[key] for r in valid]
            if values:
                print(f"  {key:13} median {sorted(values)[len(values) // 2]:8.2f}  min {min(values):8.2f}  max {max(values):8.2f}")
    if opts.json:
        with open(opts.json, "w") as out:
            json.dump(rows, out, indent=1)
    if unmeasurable:
        sys.exit(2)
    sys.exit(0 if rows and all(r.get("passed") for r in rows) else 1)


if __name__ == "__main__":
    main()
