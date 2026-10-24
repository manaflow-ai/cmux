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

Then the same on a WebKit browser tab (the engine path, WebKitEngine.prepare), read through the tab's
own requestAnimationFrame intervals (`browser.page.eval`):

  tab-low-power  macOS Low Power Mode on, then a new WebKit tab opened: WebKit halves it by itself,
                 60 fps on 120 Hz. Before row 23 the engine also gave a tab made in Low Power Mode
                 the near-60 preference: 30 fps.
  tab-full       Low Power Mode switched off with that tab on screen: the display's rate. Before,
                 the engine's live switch (write the preference, re-show the tab) did not reach the
                 shown tab, which stayed near 60.
  (With --no-low-power: `tab-full` alone, on a tab opened with Low Power Mode off.)

Each leg reads the page's own requestAnimationFrame intervals through `debug.page {action: frames}`
while the probe scrolls the page's scroller a few pixels per frame (main-thread scroll work). A leg
passes when the observed rate is nearer the rate it expects than any other rate WebKit could give
(display, display/2, display/4), so it is red on a build without the fix and green with it.

Low Power Mode is macOS's own (`sudo -n pmset -a lowpowermode 0|1`): WebKit's web processes follow
macOS, not cmux's `debug.low_power_mode` override, so only the real switch measures the product.
It is a switch for the whole host: every app on it, every WebKit page halves, and cmux's glass,
hibernation and neighbor tabs follow it. So the Low Power Mode legs run only alone on a worker,
under the controller's exclusive reservation (`CMUX_CI_STEP_CLASS=exclusive`, which the worker sets
for `cmux-ci run --class exclusive`; scripts/measure/page-cadence.sh is that entry), and the bench
refuses them anywhere else (exit 2; `--no-low-power` measures the full-rate legs only, and needs no
reservation). It switches Low Power Mode back off on every exit it can see: the end, an error,
Ctrl-C, SIGTERM and SIGHUP (a job timeout or a cancel); a SIGKILL it cannot see, so it also refuses
to start on a host that is already in Low Power Mode (a host left that way skews every bench run
on it: say so, never measure through it). Without a passwordless sudo for pmset the Low Power Mode
legs fail (they did not run).

The launch (scripts/cmux-next/bench_launch.py, P12) keeps the default engine, Chromium, so the
STRESS session (perf-stress-session.py, `--stress`) has its real Chromium pages; then
`browser.defaultEngine` is set to WebKit live and the page is opened, so the measured page is WebKit
(each reply's `engine` must say so). A display at 60 Hz or less cannot tell the rates apart: the
bench refuses it. Light and STRESS are separate launches:

  cmux-ci run --class exclusive --label measure --script scripts/measure/page-cadence.sh --ref SHA [--arg=--stress]
  scripts/cmux-next/bench-page-cadence.py --app "/path/cmux DEV <tag>.app" --no-low-power [--stress] [--runs 3] [--json out.json]

Prints one `PAGE-CADENCE {json}` line per leg and run, with host, macOS, display_fps and, for
STRESS, the `STRESS-SESSION` shape. Exit 0 when every leg of every run passed; 1 when one did not
match its rate (or did not run); 2 when the run could not measure (no WebKit page or tab, 60 Hz
display, no frames) or refused to (Low Power Mode legs without the exclusive reservation, a host
already in Low Power Mode).
"""
import argparse
import importlib.util
import json
import math
import os
import signal
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
# The browser tab's legs: (label, Low Power Mode, divisor, open a new tab first). The tab is made in
# Low Power Mode (the creation-time rate) and then Low Power Mode goes off with it on screen.
TAB_LEGS = [("tab-low-power", True, 2, True), ("tab-full", False, 1, False)]
# Without the Low Power Mode legs: one tab made at full rate.
TAB_LEGS_FULL_ONLY = [("tab-full", False, 1, True)]
# The step class the controller gives a step that runs alone on its worker (cmux-ci run --class
# exclusive); the worker exports it to the step as CMUX_CI_STEP_CLASS.
EXCLUSIVE_CLASS = "exclusive"
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


def exclusive_host():
    """Whether this run holds its worker alone (the controller's exclusive reservation)."""
    return os.environ.get("CMUX_CI_STEP_CLASS") == EXCLUSIVE_CLASS


def stop_on_signals():
    """SIGTERM and SIGHUP (a job timeout, a cancel, a closed terminal) end the bench through
    SystemExit, so every `finally` runs and Low Power Mode is switched back; Ctrl-C already does."""
    def stop(signum, _frame):
        raise SystemExit(128 + signum)
    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, stop)


def restore_low_power(found):
    """Puts macOS Low Power Mode back to `found`, with the stop signals held off, so a second
    SIGTERM cannot cut the restore short."""
    if found is None or system_low_power() == found:
        return
    held = {signum: signal.signal(signum, signal.SIG_IGN) for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
    try:
        if not set_system_low_power(found):
            print(f"bench-page-cadence: could not put macOS Low Power Mode back to {found}: "
                  "this host now skews every bench; run `sudo pmset -a lowpowermode 0`", flush=True)
    finally:
        for signum, handler in held.items():
            signal.signal(signum, handler)


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
    return judge(intervals, first.get("display_fps"), divisor, scrolled, render_rate=first.get("render_rate"))


# The tab's sampler: requestAnimationFrame intervals while it scrolls the document a few pixels per
# frame (the page's main-thread scroll work), kept on `window` between the start and the read calls,
# since `browser.page.eval` does not wait for a promise.
TAB_SAMPLE_START = """(() => {
  const state = { intervals: [], scrolled: 0, last: null, done: false, direction: 1 };
  window.__cmuxCadence = state;
  const scroller = document.scrollingElement;
  const step = (now) => {
    if (state.done) return;
    if (state.last !== null) state.intervals.push(now - state.last);
    state.last = now;
    const end = scroller ? scroller.scrollHeight - scroller.clientHeight : 0;
    if (end > 0 && PIXELS > 0) {
      if ((state.direction > 0 && scroller.scrollTop >= end) || (state.direction < 0 && scroller.scrollTop <= 0)) state.direction = -state.direction;
      const top = scroller.scrollTop;
      scroller.scrollTop = top + state.direction * PIXELS;
      state.scrolled += Math.abs(scroller.scrollTop - top);
    }
    requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
  return { chromium: /Chrome\\//.test(navigator.userAgent), ready: document.readyState };
})()"""
TAB_SAMPLE_READ = """(() => {
  const state = window.__cmuxCadence;
  if (!state) return null;
  state.done = true;
  return { intervals: state.intervals, scrolled: state.scrolled };
})()"""


def tab_eval(app, script):
    reply = app.rpc("browser.page.eval", {"script": script}, timeout=10)
    if not isinstance(reply, dict) or reply.get("error"):
        raise Unmeasurable(f"browser.page.eval: {reply}")
    return reply.get("value")


def open_webkit_tab(app, pages):
    """Opens a WebKit browser tab on a local scrolling page and waits until it has loaded."""
    reply = app.rpc("action.run", {"action": "openBrowser.webkit", "args": {"url": pages.url()},
                                   "focus": True, "origin": "script"}, timeout=30)
    if isinstance(reply, dict) and reply.get("error"):
        raise Unmeasurable(f"openBrowser.webkit: {reply['error']}")
    loaded = wait_for(lambda: (lambda v: v if v == "complete" else None)(
        (app.rpc("browser.page.eval", {"script": "document.readyState"}, timeout=5) or {}).get("value")), 30)
    if not loaded:
        raise Unmeasurable("the WebKit tab never loaded its page")


def measure_tab(app, opts, display, low_power, divisor):
    """One tab leg: the focused tab's own frame cadence over `opts.windows` windows."""
    def window():
        started = tab_eval(app, TAB_SAMPLE_START.replace("PIXELS", repr(float(opts.scroll_px))))
        if not isinstance(started, dict) or started.get("chromium"):
            raise Unmeasurable(f"the tab shows in Chromium (or did not answer: {started}): this measures nothing for row 23")
        time.sleep(WINDOW_MS / 1000)  # bench: the probe window itself, sampled by the tab's own rAF
        read = tab_eval(app, TAB_SAMPLE_READ)
        if not isinstance(read, dict):
            raise Unmeasurable(f"the tab lost its sampler (navigated or reloaded): {read}")
        return read
    window()  # holds the switch (WebKit adjusts the rate on its next activity): read and dropped
    intervals, scrolled = [], 0.0
    for _ in range(opts.windows):
        if (app.rpc("debug.low_power_mode") or {}).get("system") is not low_power:
            raise Unmeasurable(f"macOS Low Power Mode is not {low_power} during the tab leg")
        read = window()
        if (read.get("scrolled") or 0) <= 0:
            raise Unmeasurable("the tab's document did not scroll: the window measured an idle page")
        scrolled += read["scrolled"]
        intervals.extend(v for v in read.get("intervals") or [] if isinstance(v, (int, float)))
    return judge(intervals, display, divisor, scrolled, render_rate=None)


def judge(intervals, display, divisor, scrolled, render_rate):
    if not isinstance(display, (int, float)) or display <= 60:
        raise Unmeasurable(f"display_fps {display}: at 60 Hz or less the rates cannot be told apart; use a 120 Hz host")
    if not intervals:
        raise Unmeasurable("rendered no frames (hidden or covered)")
    observed = len(intervals) * 1000 / sum(intervals)
    nearest = min(DIVISORS, key=lambda d: abs(observed - display / d))
    return {
        "render_rate": render_rate, "display_fps": display, "frames": len(intervals),
        "observed_fps": round(observed, 1), "expected_fps": round(display / divisor, 1),
        "passed": nearest == divisor, "scrolled_px": round(scrolled, 1),
        "p50_ms": round(nearest_rank(intervals, 0.5), 2), "p95_ms": round(nearest_rank(intervals, 0.95), 2),
        "max_ms": round(max(intervals), 2), "long_frames": sum(1 for v in intervals if v > 1.5 * 1000 / display),
    }


def switch_low_power(app, low_power):
    """Switches macOS Low Power Mode and waits until the app hears it; an error text when it could not."""
    if low_power != system_low_power() and not set_system_low_power(low_power):
        return f"cannot switch macOS Low Power Mode to {low_power} (sudo -n pmset); this leg did not run"
    # The app (and every web process) hears NSProcessInfoPowerStateDidChange.
    if not wait_for(lambda: (app.rpc("debug.low_power_mode") or {}).get("system") is low_power, 10):
        return f"the app never saw Low Power Mode {low_power}"
    return None


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
        display = None
        for label, low_power, divisor in legs:
            row = {"leg": label, "run": index, **facts, **session, "page": opts.page}
            error = switch_low_power(app, low_power)
            if error:
                row.update(error=error)
            else:
                row.update(measure(app, opts, selector, low_power, divisor))
                display = row["display_fps"]
            results.append(row)
            print(f"PAGE-CADENCE {json.dumps(row)}", flush=True)
        # The browser tab, on the display the page legs read (the same window).
        pages = load_stress().Pages()
        for label, low_power, divisor, opens in (TAB_LEGS_FULL_ONLY if opts.no_low_power else TAB_LEGS):
            row = {"leg": label, "run": index, **facts, **session, "target": "webkit-tab"}
            error = switch_low_power(app, low_power) or (None if display else "no page leg read the display rate")
            if error:
                row.update(error=error)
            else:
                if opens:
                    open_webkit_tab(app, pages)
                    time.sleep(1.0)  # bench: the tab's first frames end before the windows
                row.update(measure_tab(app, opts, display, low_power, divisor))
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
                        help="measure the full-rate legs only: no Low Power Mode switch, so no exclusive host needed")
    parser.add_argument("--json")
    opts = parser.parse_args()
    stop_on_signals()
    facts = host_facts()
    found = system_low_power()
    print(f"host {facts} low_power_mode {found} step_class {os.environ.get('CMUX_CI_STEP_CLASS')} "
          f"load average {os.getloadavg()}", flush=True)
    if found:
        # Every leg expects Low Power Mode off at its start; a host left in it (a SIGKILLed run, a
        # person) halves every WebKit page, so no number from it means what the bench says.
        print(f"PAGE-CADENCE {json.dumps({**facts, 'error': 'macOS Low Power Mode is on before the bench started: refusing to measure through it (sudo pmset -a lowpowermode 0)'})}", flush=True)
        sys.exit(2)
    if not opts.no_low_power and not exclusive_host():
        print(f"PAGE-CADENCE {json.dumps({**facts, 'error': 'the Low Power Mode legs switch it for the whole host: run them alone on a worker (cmux-ci run --class exclusive --script scripts/measure/page-cadence.sh), or pass --no-low-power'})}", flush=True)
        sys.exit(2)
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
        restore_low_power(found)
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
