"""split-scale-bench.py's judge: one transition's numbers from its frame strip and its motion trace, the cell summary,
the pass/fail targets and the one-screen table. Standard library only, apart from the bench so a test can call it
(python3 scripts/cmux-next/test_split_scale_metrics.py).

Per transition the bench hands this two records of the same gesture:

  strip  `debug.new_tab frame_strip` (the window as the window server composited it, frame after frame; `ms` from the
         input): first_change_ms, the frames' outside/content shares against before and the final picture, `blank`
  trace  `debug.motion trace_stop` (every display-link tick of the window: `t` ms, each pane host's rect and laid-out
         content, each divider, each terminal surface and Chromium page; refresh_ms)

and gets back:

  first_frame_ms   input to the first display-link tick whose layout differs (the trace lined up with the input by
                   frame_strip's `sent_host_s`); a build without it falls back to the first changed composited frame
  settled_ms       input to the last tick that moved anything; for static content (empty terminal, chat) no earlier
                   than the first frame of the composited settled run (every later frame equals the last), so paint
                   that comes after the panes landed counts
  frame_p50/p95/max_ms  display-link intervals while anything in the trace moved (one frame before the first move to
                   the last move): the transition's own frame times, not the idle ticks around it
  dropped_frames   those intervals longer than 1.5 refresh periods
  blank_frames     frames the strip marked blank (the content area one flat color that is neither before nor final)
  partial_frames   frames after the window outside the content landed whose content is still not final: content
                   that paints after its pane stopped moving (a pane grown into an unpainted area)
  retargets        a mover whose motion reversed along an axis, or sped up again after it had started to slow
                   (a new target mid-flight; the house curve decelerates once, with no overshoot), read on its edges
                   (left, top, right, bottom), each on the pixel grid as the window shows it, not on its width and height
"""
from __future__ import annotations

import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from one_motion_series import EPS, PANE_FRAME, series  # noqa: E402

TOLERANCE = 0.002
# A re-acceleration counts as a retarget only past this speed (points per ms) and this ratio over the slowest speed
# since the peak: a dropped frame or a rounding step must not read as a new target.
RETARGET_MIN_SPEED = 0.05
RETARGET_RATIO = 1.5
# The window places each edge on the pixel grid (whole points at scale 1), so a step between two shown edges is off its
# spring's by up to one point: a re-acceleration counts only when the step is more than this over the slowest one.
RETARGET_SLACK = 1.0
# The pane frame's width in a trace pane row (one_motion_series PANE_FRAME: fx, fy, fwidth, fheight).
PANE_FRAME_WIDTH = PANE_FRAME.start + 2

TARGETS = {
    "first_frame_ms": 16.0,
    "settled_ms": 120.0,
    "blank_frames": 0,
    "retargets": 0,
    "flatness_ratio": 1.2,
}


def p95_target(refresh_ms):
    """8.3 ms on a 120 Hz (ProMotion) display, 16.7 ms otherwise."""
    return 8.34 if refresh_ms and refresh_ms < 10 else 16.7


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def pct(values, q):
    values = sorted(v for v in values if _number(v))
    if not values:
        return None
    return round(values[min(len(values) - 1, int(round((len(values) - 1) * q)))], 2)


# A page window this far left of every screen is parked (a pre-warmed page the app keeps off screen): its resize after
# a split is deferred off-screen work, which nobody sees, so it is not a mover (split-scale smoke 7bd5eed3: x -99840).
PARKED_X = -10000


def trace_movers(samples):
    """{mover: [(t, values)]}: one_motion_series' movers plus every divider (`divider ID`), less the parked pages
    (every point's page window x left of PARKED_X)."""
    out = {key: points for key, points in series(samples).items()
           if not (key.startswith("page ") and points and all(p[1][0] < PARKED_X for p in points))}
    for sample in samples:
        t = float(sample.get("t", 0))
        for row in sample.get("dividers") or []:
            if isinstance(row, list) and len(row) >= 5:
                out.setdefault(f"divider {str(row[0])[-12:]}", []).append((t, tuple(round(float(v), 2) for v in row[1:5])))
    return out


def edges(key, points):
    """`points` with each rect as its edges: a pane's frame or content, a terminal and a divider (x, y, width, height)
    as (left, top, right, bottom), a page window (x, width, height) as (left, right, height). The window shows edges,
    each placed on the pixel grid on its own (ScreenContentView.pixelEdges), so a height is the difference of two
    rounded edges: when both edges of a pane move, at different speeds (the bottom pane of a column that a Split Down
    or its close resizes: its top follows the divider above it, its bottom the one below), the height's steps differ
    by up to a point a frame even though each edge decelerates once, and that read as a retarget. Edges are what moves
    on the spring, so a target change shows on one of them."""
    if key.startswith("page "):
        return [(t, (v[0], v[0] + v[1]) + tuple(v[2:]) if len(v) >= 2 else v) for t, v in points]
    if key.endswith(" frame") or key.endswith(" content") or key.startswith(("terminal ", "divider ")):
        return [(t, (v[0], v[1], v[0] + v[2], v[1] + v[3]) if len(v) == 4 else v) for t, v in points]
    return points


def retargets(points):
    """The ticks (ms) at which a mover's target changed mid-flight, on any axis: the motion reversed, or it sped up by
    RETARGET_RATIO (and more than RETARGET_SLACK points) over the slowest step since it last started. Values whose length changes (a row that came or went)
    restart the run there."""
    turned = set()
    if len(points) < 3:
        return turned
    width = len(points[0][1])
    for axis in range(width):
        sign, slowest = 0, None
        for (t0, v0), (t1, v1) in zip(points, points[1:]):
            if len(v0) != width or len(v1) != width or t1 <= t0:
                sign, slowest = 0, None
                continue
            delta = v1[axis] - v0[axis]
            if abs(delta) <= EPS:
                continue
            speed = abs(delta) / (t1 - t0)
            step = 1 if delta > 0 else -1
            if sign and step != sign:
                turned.add(t1)
                slowest = None
            elif (slowest is not None and speed > RETARGET_MIN_SPEED and speed > slowest * RETARGET_RATIO
                  and abs(delta) - slowest * (t1 - t0) > RETARGET_SLACK + 1e-6):
                turned.add(t1)
                slowest = None
            elif sign:
                slowest = speed if slowest is None else min(slowest, speed)
            sign = step
    return turned


def trace_stats(trace, sent_host_s=None):
    """The transition's display-link frame times, dropped frames and retargets from a trace_stop report. With
    `sent_host_s` (the input's host time, frame_strip's `sent_host_s`; the trace's `t0_s` shares its clock) it also
    gives the layout's own times from the input: `layout_first_ms` (the first tick whose geometry differs) and
    `layout_settled_ms` (the last tick that moved anything), and leaves out what moved before the input."""
    samples = [s for s in (trace or {}).get("samples") or [] if _number(s.get("t"))]
    refresh = (trace or {}).get("refresh_ms") or None
    t0 = (trace or {}).get("t0_s")
    sent = (sent_host_s - t0) * 1000 if _number(sent_host_s) and _number(t0) and t0 > 0 else None
    if sent is not None:
        # One tick before the input stays in, as the reference the first move is measured against.
        before = [x for x in samples if x["t"] < sent]
        samples = before[-1:] + [x for x in samples if x["t"] >= sent]
    movers = trace_movers(samples)
    first = last = None
    turns, ticks, ends = {}, set(), {}
    for key, points in movers.items():
        for (_, v0), (t1, v1) in zip(points, points[1:]):
            if len(v0) != len(v1) or any(abs(a - b) > EPS for a, b in zip(v0, v1)):
                first = t1 if first is None else min(first, t1)
                last = t1 if last is None else max(last, t1)
                step = max((abs(a - b) for a, b in zip(v0, v1)), default=None) if len(v0) == len(v1) else None
                moves = ends.get(key, (0, 0, None, None, 0))[4] + 1
                ends[key] = (t1, step, list(v0), list(v1), moves)
        turned = retargets(edges(key, points))
        if turned:
            turns[key] = len(turned)
            ticks |= turned
    times = [x["t"] for x in samples]
    intervals = []
    if first is not None:
        window = [t for t in times if t >= first - (refresh or 8.34) * 1.01 and t <= last]
        # The interval that ends at the first moved tick counts: it is the frame the transition first showed in.
        earlier = [t for t in times if t < first]
        if earlier and (not window or window[0] >= first):
            window = [earlier[-1]] + window
        intervals = [round(b - a, 2) for a, b in zip(window, window[1:]) if b > a]
    dropped = sum(1 for i in intervals if refresh and i > refresh * 1.5)
    out = {"refresh_ms": refresh, "motion_ms": round(last - first, 1) if first is not None else 0,
           "moved_frames": len(intervals), "frame_p50_ms": pct(intervals, 0.5), "frame_p95_ms": pct(intervals, 0.95),
           "frame_max_ms": max(intervals) if intervals else None, "dropped_frames": dropped,
           "retargets": len(ticks), "retargeted": turns, "movers": len(movers), "aligned": sent is not None}
    if sent is not None:
        out["layout_first_ms"] = round(first - sent, 1) if first is not None else None
        out["layout_settled_ms"] = round(last - sent, 1) if last is not None else None
    # What settled last (mover, its last move from the input or the trace's start, that move's largest step in points,
    # its values before and after that move, how many ticks it moved): a settle the screen never shows (a hidden view,
    # a page window that jumps once, an index that moved to another page) reads here.
    origin = sent if sent is not None else (times[0] if times else 0)
    out["last_movers"] = [[str(key), round(t - origin, 1), round(step, 2) if _number(step) else None, before, after, moves]
                          for key, (t, step, before, after, moves) in sorted(ends.items(), key=lambda kv: -kv[1][0])[:4]]
    out["pane_width_change"] = pane_width_change(samples)
    out["pane_width_peak"] = pane_width_peak(samples)
    return out


def _pane_widths(sample):
    return {str(row[0]): float(row[PANE_FRAME_WIDTH]) for row in sample.get("panes") or []
            if isinstance(row, list) and len(row) > PANE_FRAME_WIDTH and _number(row[PANE_FRAME_WIDTH])}


def _width_change(start, sample):
    end = _pane_widths(sample)
    both = start.keys() & end.keys()
    return round(sum(end[p] - start[p] for p in both), 1) if both else None


def pane_width_change(samples):
    """The panes' summed frame width at the trace's last tick minus at its first, over the panes in both (points):
    negative when the panes narrowed (a right sidebar opened beside them), positive when they widened (it closed),
    None without a pane in both. The side pane's toggle is one key for both ways, so this says which way it went."""
    return _width_change(_pane_widths(samples[0]), samples[-1]) if samples else None


def pane_width_peak(samples):
    """The same change at the tick where it was largest (signed): a toggle whose panes moved and came back (net change
    0) still shows which way they went. None without a pane in any tick and the first."""
    if not samples:
        return None
    start = _pane_widths(samples[0])
    changes = [c for c in (_width_change(start, s) for s in samples[1:]) if c is not None]
    return max(changes, key=abs) if changes else None


def side_way(row):
    """Which way a side pane toggle went in `row` (a transition record): "opened" (the panes narrowed), "closed"
    (they widened), or None (they kept their width, or the trace had none). The net change decides; a toggle whose
    panes came back to their width goes by its peak (side_toggle records that as the round's error)."""
    change = (row or {}).get("pane_width_change")
    if not _number(change) or abs(change) <= EPS:
        change = (row or {}).get("pane_width_peak")
    if not _number(change) or abs(change) <= EPS:
        return None
    return "opened" if change < 0 else "closed"


def side_returned(row):
    """True when the panes moved (a peak) but ended at the width they started at: the toggle undid itself."""
    change, peak = (row or {}).get("pane_width_change"), (row or {}).get("pane_width_peak")
    return _number(peak) and abs(peak) > EPS and _number(change) and abs(change) <= EPS


def strip_stats(strip, tolerance=TOLERANCE, settle_frames=6):
    """first_frame_ms, settled_ms, blank and partial frames from a frame_strip reply."""
    rows = sorted((f for f in (strip or {}).get("frames") or [] if _number(f.get("ms"))), key=lambda f: f["ms"])
    after = [f for f in rows if f["ms"] > 0]

    def changed(f, key):
        return (f.get(key) or 0) > tolerance
    first = strip.get("first_change_ms") if _number((strip or {}).get("first_change_ms")) else None
    if first is None:
        first = next((f["ms"] for f in after if changed(f, "outside_vs_before") or changed(f, "content_vs_before")), None)
    else:
        outside = next((f["ms"] for f in after if changed(f, "outside_vs_before")), None)
        first = min(first, outside) if outside is not None else first
    settled = None
    for index, frame in enumerate(after):
        rest = after[index:]
        if all(not changed(f, "outside_vs_final") and not changed(f, "content_vs_final") for f in rest):
            settled = frame["ms"] if len(rest) >= settle_frames else None
            break
    landed = next((i for i, f in enumerate(after) if all(not changed(g, "outside_vs_final") for g in after[i:])), None)
    partial = 0
    if landed is not None:
        partial = sum(1 for f in after[landed:] if changed(f, "content_vs_final") and f["ms"] > (first or 0))
    return {"first_frame_ms": first, "settled_ms": settled, "blank_frames": sum(1 for f in after if f.get("blank")),
            "partial_frames": partial, "strip_frames": len(after), "strip_interval_ms": (strip or {}).get("mean_interval_ms")}


def transition(strip, trace, tolerance=TOLERANCE, static=True):
    """One transition's record from its strip and trace (either may be an error dict); `error` says why a round
    measured nothing usable, and such a round fails its cell.

    `static`: the panes' content holds still when nothing is done (an empty terminal, a chat). Streaming output or an
    animating page (scrollback, browser) keeps changing pixels, so their pixel times say nothing about the transition:
    first frame and settled then come from the trace alone (the layout's ticks from the input), and partial frames
    are not judged. For static content the pixel settle counts too, so content that paints after the panes landed
    delays settled."""
    out, errors = {}, []
    pixels = {}
    if strip and not strip.get("error"):
        pixels = strip_stats(strip, tolerance)
    else:
        errors.append(f"strip: {str((strip or {}).get('error') or 'none')[:300]}")
    sent = (strip or {}).get("sent_host_s")
    timed = {}
    if trace and not trace.get("error"):
        timed = trace_stats(trace, sent)
        out.update(timed)
    else:
        errors.append(f"trace: {str((trace or {}).get('error') or 'none')[:300]}")
    out["blank_frames"] = pixels.get("blank_frames")
    out["partial_frames"] = pixels.get("partial_frames") if static else None
    out["pixel_first_ms"], out["pixel_settled_ms"] = pixels.get("first_frame_ms"), pixels.get("settled_ms")
    if timed.get("aligned"):
        out["first_frame_ms"] = timed.get("layout_first_ms")
        settled = timed.get("layout_settled_ms")
        if static and settled is not None:
            pixel = pixels.get("settled_ms")
            settled = None if pixel is None else max(settled, pixel)
        out["settled_ms"] = settled
        if timed.get("layout_first_ms") is None:
            errors.append("nothing moved after the input")
    elif static:
        out["first_frame_ms"], out["settled_ms"] = pixels.get("first_frame_ms"), pixels.get("settled_ms")
    else:
        errors.append("no input time (a build without frame_strip sent_host_s): streaming content has no pixel timing")
    if errors:
        out["error"] = "; ".join(errors)
    return out


SUMMARY_KEYS = ("first_frame_ms", "settled_ms", "frame_p50_ms", "frame_p95_ms", "frame_max_ms", "dropped_frames",
                "blank_frames", "partial_frames", "retargets", "motion_ms")


def summarize(records):
    """A cell's transition over its rounds: the median of each number, except blank, partial and retargets, which
    take the worst round (one blank frame in any round is a blank frame), and frame max and dropped, the max. A round
    with an `error` (no measurement, or a gesture that did nothing) is counted in `failed_rounds`, which fails the
    cell; its numbers are not borrowed from the other rounds."""
    good = [r for r in records if not r.get("error")]
    out = {"rounds": len(records), "failed_rounds": len(records) - len(good),
           "errors": [r["error"] for r in records if r.get("error")][:3]}
    for key in SUMMARY_KEYS:
        values = [r.get(key) for r in good if _number(r.get(key))]
        if not values:
            out[key] = None
        elif key in ("blank_frames", "partial_frames", "retargets", "frame_max_ms", "dropped_frames"):
            out[key] = max(values)
        else:
            out[key] = round(statistics.median(values), 2)
    out["unsettled"] = sum(1 for r in good if r.get("settled_ms") is None)
    out["refresh_ms"] = next((r.get("refresh_ms") for r in good if r.get("refresh_ms")), None)
    return out


def verdict(summary, refresh_ms=None):
    """{target: True/False/None} for one cell's transition summary; None: not measured. A failed round, a round that
    never settled or a target with no measurement fails the cell."""
    refresh = refresh_ms or summary.get("refresh_ms")

    def under(key, limit):
        value = summary.get(key)
        return None if value is None else value <= limit
    checks = {
        "complete": summary.get("rounds", 0) > 0 and not summary.get("failed_rounds"),
        "first_frame": under("first_frame_ms", TARGETS["first_frame_ms"]),
        "settled": under("settled_ms", TARGETS["settled_ms"]) if not summary.get("unsettled") else False,
        "p95": under("frame_p95_ms", p95_target(refresh)),
        "blank": under("blank_frames", TARGETS["blank_frames"]),
        "retargets": under("retargets", TARGETS["retargets"]),
    }
    checks["pass"] = all(v is True for v in checks.values())
    return checks


def flatness(cells, key="settled_ms"):
    """Per transition, the worst cell's `key` over the smallest cell's (the smallest: 1 split, empty terminal,
    1 workspace when measured, else the lowest value). Cells: {cell name: {transition: summary}}."""
    out = {}
    transitions = sorted({t for per in cells.values() for t in per})
    for name in transitions:
        values = {cell: per[name].get(key) for cell, per in cells.items() if name in per and _number(per[name].get(key))}
        if not values:
            continue
        base_cell = "s1-empty-w1" if "s1-empty-w1" in values else min(values, key=values.get)
        base = values[base_cell]
        worst_cell = max(values, key=values.get)
        ratio = round(values[worst_cell] / base, 2) if base > 0 else None
        out[name] = {"base_cell": base_cell, "base": base, "worst_cell": worst_cell, "worst": values[worst_cell],
                     "ratio": ratio, "pass": ratio is not None and ratio <= TARGETS["flatness_ratio"]}
    return out


def _fmt(value, width):
    text = "-" if value is None else (f"{value:.0f}" if isinstance(value, float) and value >= 100 else
                                       f"{value:.1f}" if isinstance(value, float) else str(value))
    return text.rjust(width)


def table(report):
    """The one-screen table: per transition its worst cell by settled time, with first frame, frame p95/max, blank
    and partial frames, retargets and the flatness ratio, then the failing cell count."""
    cells = report.get("cells") or {}
    flat = report.get("flatness") or {}
    lines = [f"split-scale  {report.get('app_version') or ''}  {report.get('host') or ''}  "
             f"refresh {report.get('refresh_ms') or '-'} ms  cells {len(cells)}",
             f"{'transition':<15}{'worst cell':<22}{'first':>7}{'settled':>9}{'p95':>7}{'max':>7}{'drop':>6}"
             f"{'blank':>6}{'part':>6}{'retgt':>6}{'flat':>7}{'fail':>6}"]
    names = sorted({t for per in cells.values() for t in per})
    for name in names:
        rows = {cell: per[name] for cell, per in cells.items() if name in per}
        worst = max(rows, key=lambda c: (rows[c].get("settled_ms") is None, rows[c].get("settled_ms") or 0))
        s = rows[worst]
        failing = sum(1 for summary in rows.values() if not verdict(summary, report.get("refresh_ms"))["pass"])
        ratio = (flat.get(name) or {}).get("ratio")
        lines.append(f"{name:<15}{worst:<22}{_fmt(s.get('first_frame_ms'), 7)}{_fmt(s.get('settled_ms'), 9)}"
                     f"{_fmt(s.get('frame_p95_ms'), 7)}{_fmt(s.get('frame_max_ms'), 7)}{_fmt(s.get('dropped_frames'), 6)}"
                     f"{_fmt(s.get('blank_frames'), 6)}{_fmt(s.get('partial_frames'), 6)}{_fmt(s.get('retargets'), 6)}"
                     f"{_fmt(ratio, 7)}{(str(failing) + '/' + str(len(rows))).rjust(6)}")
    targets = (f"targets: first <= {TARGETS['first_frame_ms']:.0f} ms, settled <= {TARGETS['settled_ms']:.0f} ms, "
               f"p95 <= {p95_target(report.get('refresh_ms'))} ms, 0 blank, 0 retargets, worst/smallest <= "
               f"{TARGETS['flatness_ratio']}x")
    lines.append(targets)
    overall = report.get("worst") or {}
    if overall:
        lines.append(f"worst cell: {overall.get('cell')} {overall.get('transition')} settled {overall.get('settled_ms')} ms"
                     f" (flat ratio {overall.get('ratio')}); passing cells {report.get('passing')}/{report.get('measured')}")
    return "\n".join(lines)


def headline(cells, flat):
    """The goal check's one number: the worst cell's settled time over all transitions, with the cell, its
    transition and the worst flatness ratio. A cell with a failed or unsettled round is the worst (settled None)."""
    worst = None
    for cell, per in cells.items():
        for name, summary in per.items():
            value = summary.get("settled_ms")
            if summary.get("unsettled") or summary.get("failed_rounds") or value is None:
                value = float("inf")
            if worst is None or value > worst["settled_ms"]:
                worst = {"cell": cell, "transition": name, "settled_ms": value}
    if worst is None:
        return {}
    if worst["settled_ms"] == float("inf"):
        worst["settled_ms"] = None
    ratios = [f.get("ratio") for f in flat.values() if _number(f.get("ratio"))]
    worst["ratio"] = max(ratios) if ratios else None
    return worst
