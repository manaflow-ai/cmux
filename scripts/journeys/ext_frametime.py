"""Frame timing around one moment, from the app's own surface counters (journeys/p1/window-uncover-draws.json).

driver.py loads this file (load_extensions) on the mini, under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead.

A frame check reads a window snapshot about once a second, so it cannot say whether a window shown again drew
its current content within one frame (lead 2026-10-28). This group samples `debug.surfaces` for one pane on a
background thread, every INTERVAL ms, and keeps each sample's socket time before and after the read, the
surface's pause and Ghostty's frame counter (`render_counters.frames`). The first draw after the pause ends lies
between two samples; the conditions report that interval, never a single number finer than the sampling.

Steps (`do`):
  frame_watch {as, pane?, interval_ms?, seconds?}
                                 starts sampling the journey's pane (or the named pane) every INTERVAL ms
                                 (default 4) for SECONDS (default 8); the samples are kept as AS
An app that records the show itself (`debug.surfaces` surface.show {unpaused_ns, first_frame_ns,
unpause_to_frame_ms}, Debug and bench builds since cp/terminal-show-timing) is judged by that record: exact,
written off the main thread's queue. The 4 ms samples are the fallback for an app without it.

Conditions (inside `expect.all`; evidence kind app):
  shown_draws_within {watch, since, frame_ms?}
                                 after the mark SINCE: the first sample with no pause (the window seen again), then
                                 the first sample whose frame counter grew past the last paused one. Holds when
                                 the draw's upper bound (its sample's read end) is at most FRAME_MS (default 16.7)
                                 after the unpause's lower bound (the read start of the last paused sample).
                                 Reports both bounds of: key to unpause, unpause to first frame, key to first frame.
"""
import threading
import time

D = None  # the driver module (install)


def install(driver):
    global D
    D = driver


def _row(report, pane):
    for window in (report or {}).get("windows", []):
        for row in window.get("panes", []) or []:
            if isinstance(row, dict) and row.get("pane") == pane:
                return row
    return None


def step_frame_watch(j, step):
    named = getattr(j, "ext_panes", {})  # ext_window's name_pane / adopt_pane
    if step.get("pane") and step["pane"] not in named:
        raise D.StepError(f"frame_watch: no pane named {step['pane']!r}")
    pane = named[step["pane"]]["pane"] if step.get("pane") else j.pane
    if not pane:
        raise D.StepError("frame_watch: no pane (new_terminal first)")
    interval = float(step.get("interval_ms", 4)) / 1000.0
    until = D.now() + float(step.get("seconds", 8))
    samples = []

    def sample():
        while D.now() < until:
            t0 = D.now()
            try:
                row = _row(j.app.rpc("debug.surfaces", {}), pane)
            except (D.StepError, OSError, ValueError):
                row = None
            t1 = D.now()
            surface = (row or {}).get("surface") or {}
            counters = surface.get("render_counters") or {}
            samples.append({"t0": t0, "t1": t1, "paused": surface.get("paused"),
                            "occluded": (row or {}).get("window_occluded"), "frames": counters.get("frames")})
            left = interval - (D.now() - t0)
            if left > 0:
                time.sleep(left)

    thread = threading.Thread(target=sample, daemon=True)
    thread.start()
    if not hasattr(j, "frame_watches"):
        j.frame_watches = {}
    j.frame_watches[step["as"]] = {"pane": pane, "samples": samples, "thread": thread, "interval_ms": interval * 1000}
    return {"pane": pane, "interval_ms": interval * 1000}


def _ms(a, b):
    return round((a - b) * 1000, 1)


def _uptime_minus_monotonic():
    """CLOCK_UPTIME_RAW minus time.monotonic(), in seconds (0 where the uptime clock does not exist)."""
    raw = getattr(time, "CLOCK_UPTIME_RAW", None)
    if raw is None:
        return 0.0
    return time.clock_gettime(raw) - time.monotonic()


def _app_show(j, pane):
    """The app's own record of the pane's last unpause and first frame after it (`debug.surfaces`
    surface.show, cp/terminal-show-timing); None when this app has none."""
    try:
        row = _row(j.app.rpc("debug.surfaces", {}), pane)
    except (D.StepError, OSError, ValueError):
        return None
    show = ((row or {}).get("surface") or {}).get("show")
    return show if isinstance(show, dict) else None


def cond_shown_draws_within(j, want, cache):
    watch = j.frame_watches[want["watch"]]
    budget = float(want.get("frame_ms", 16.7))
    show = _app_show(j, watch["pane"])
    if show is not None:
        # The app's record: exact, off the main thread's queue. Its unpause must be after the mark. The app's
        # times are CLOCK_UPTIME_RAW; the driver's marks are time.monotonic() (mach_absolute_time in CPython on
        # macOS, the same clock today): the mark moves by the two clocks' offset read now, in case they differ.
        mark_ns = (j.marks[want["since"]] + _uptime_minus_monotonic()) * 1e9
        detail = {"pane": watch["pane"], "source": "app", "show": show, "frame_ms": budget}
        if show.get("unpaused_ns") is None or show["unpaused_ns"] < mark_ns - 1e6:
            return False, dict(detail, waiting="no unpause after the mark yet")
        if show.get("unpause_to_frame_ms") is None:
            return False, dict(detail, waiting="no frame since the unpause")
        detail["key_to_unpause_ms"] = round((show["unpaused_ns"] - mark_ns) / 1e6, 2)
        return show["unpause_to_frame_ms"] <= budget, detail
    mark = j.marks[want["since"]]
    samples = list(watch["samples"])
    reads = [s["t1"] - s["t0"] for s in samples]
    detail = {"pane": watch["pane"], "samples": len(samples),
              "read_ms_p50": round(sorted(reads)[len(reads) // 2] * 1000, 2) if reads else None,
              "read_ms_max": round(max(reads) * 1000, 2) if reads else None}
    after = [i for i, s in enumerate(samples) if s["t0"] >= mark]
    if not after:
        return False, dict(detail, waiting="no sample after the mark yet")
    first = after[0]
    shown = next((i for i in after if samples[i]["paused"] is None and samples[i]["frames"] is not None), None)
    if shown is None:
        return False, dict(detail, waiting="still paused", last=samples[-1])
    if shown == first:
        # Never seen paused after the mark: the window was not covered at the uncover (no measurement).
        return False, dict(detail, error="the pane was not paused at the mark; nothing to measure")
    # The last paused sample that read the surface (a failed read has no pause and no counter).
    last_paused = next((i for i in range(shown - 1, first - 1, -1)
                        if samples[i]["paused"] is not None and samples[i]["frames"] is not None), None)
    if last_paused is None:
        return False, dict(detail, error="no readable paused sample after the mark; nothing to measure")
    base = samples[last_paused]["frames"]
    drew = next((i for i in range(shown, len(samples))
                 if samples[i]["frames"] is not None and samples[i]["frames"] > base), None)
    if drew is None:
        return False, dict(detail, waiting="no new frame since the unpause", frames=base)
    unpause_lo, unpause_hi = samples[last_paused]["t0"], samples[shown]["t1"]
    draw_lo, draw_hi = samples[drew - 1]["t0"], samples[drew]["t1"]
    show_to_draw_hi = _ms(draw_hi, unpause_lo)
    detail.update({
        "key_to_unpause_ms": [_ms(unpause_lo, mark), _ms(unpause_hi, mark)],
        "unpause_to_frame_ms": [max(0.0, _ms(draw_lo, unpause_hi)), show_to_draw_hi],
        "key_to_frame_ms": [_ms(draw_lo, mark), _ms(draw_hi, mark)],
        "frames": [base, samples[drew]["frames"]],
        "frame_ms": budget,
        # The widest sample gap the answer depends on: a main-thread stall makes debug.surfaces (a main-actor
        # read) wait, so the unpause and the draw can fall in one gap; then the bound is that gap, not a frame.
        "resolution_ms": _ms(max(unpause_hi - unpause_lo, draw_hi - draw_lo), 0),
    })
    return show_to_draw_hi <= budget, detail


STEPS = {"frame_watch": step_frame_watch}
CONDITIONS = {"shown_draws_within": ("app", cond_shown_draws_within)}
