"""split-scale-bench.py's judge for a MOVE: a pane or a tab that goes from one split to another (Leo, 2026-11-22:
"the layout shifts from panes moving back and forth between splits ... the content within needs to be settling
instantly without extraneous movement. likewise with splits themselves").

A move is right when the frame that first shows the new layout shows all of it: every pane, every pane's content,
every terminal surface and every page at its final rect or on one move toward it that never turns back, never
stops and starts again, and never starts late. Per move the bench hands this the same two records as a transition
(split_scale_metrics.py): the motion trace (every display-link tick: each pane host's shown rect, its frame, its
content's laid-out rect, each divider, terminal surface and Chromium page window) and the frame strip (the window as
composited, each frame's share of pixels that differ from the picture before and from the final one). `move()` gives:

  commit_ms            input to the first tick whose layout differs: the frame that shows the new layout
  rest_ms, frames_to_rest  input to the last tick anything moved, and the ticks from the commit tick to it
  displacement         per mover, per tick from the commit: the largest distance (points) of one of its edges from
                       where it ends (`series`, kept for the movers that break a rule and the four that moved longest)
  moved_after_commit   movers that changed in a tick after the commit tick other than on their one move: a move that
                       began later than the tick after the commit (late), a second move after the mover had stopped
                       for more than one tick (again), a step away from where it ends (back). `_frames`: the ticks in
                       which that happened; `_px`: the largest distance from its final rect a mover had in one of them
  content_off_pane     ticks in which a pane's laid-out content is not where its frame puts it: the offsets between the
                       content's edges and the frame's are not the ones the pane has at rest. `_px`: the largest
  reversals            split_scale_metrics' retargets (a mover that reversed or sped up again) plus `pixel_reversals`:
                       composited frames whose share of pixels off the final picture rose again after it had fallen
  pixel_after_commit   composited frames after the first changed one that are not yet the final picture (`_ms`: from
                       the first changed frame to the settled one): how long the screen kept changing
  blank_frames, partial_frames  as split_scale_metrics (the content area one flat color; content still painting after
                       the outside landed)
  reloads              tabs of the measured workspace that were made again: an id that was not there before the move
                       (the bench passes the ids; a respawned source tab is expected and passed apart)

`verdict()` passes a move with 0 moved_after_commit, 0 content_off_pane, 0 reversals, 0 blank frames, 0 partial frames
(static content) and 0 reloads. Standard library only (python3 scripts/cmux-next/test_split_move_metrics.py).
"""
from __future__ import annotations

import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import split_scale_metrics as ssm  # noqa: E402
from one_motion_series import EPS, PANE_CONTENT, PANE_FRAME, PANE_ROW  # noqa: E402

# A mover may skip one tick inside its move (a dropped frame, a step under EPS at the spring's tail) and it is still
# the same move; a longer stop and a new start is a second move.
GAP_TICKS = 1
# A move that begins in the commit tick or the one after it began with the layout; later is late.
LATE_TICKS = 1
# A composited frame's share off the final picture must rise by more than this over the lowest share seen to count as
# a reversal: the strip's own noise (a blinking cursor, a streaming terminal) stays under it.
PIXEL_RISE = 0.01
KEPT_SERIES = 4

JUDGED = ("moved_after_commit", "content_off_pane", "reversals", "blank_frames", "partial_frames", "reloads")
SUMMARY_KEYS = ("commit_ms", "rest_ms", "frames_to_rest", "moved_after_commit", "moved_after_commit_frames",
                "moved_after_commit_px", "content_off_pane", "content_off_pane_px", "reversals", "retargets",
                "pixel_reversals", "pixel_after_commit", "pixel_after_commit_ms", "blank_frames", "partial_frames",
                "reloads")
WORST = set(SUMMARY_KEYS) - {"commit_ms", "rest_ms", "frames_to_rest", "pixel_after_commit", "pixel_after_commit_ms"}


def _after_input(trace, sent_host_s):
    """(samples from the last tick before the input on, the input's time in the trace's ms or None, refresh ms): the
    same cut as split_scale_metrics.trace_stats (a tick stamped within one refresh before the input was read after it)."""
    samples = [s for s in (trace or {}).get("samples") or [] if ssm._number(s.get("t"))]
    refresh = (trace or {}).get("refresh_ms") or None
    t0 = (trace or {}).get("t0_s")
    sent = (sent_host_s - t0) * 1000 if ssm._number(sent_host_s) and ssm._number(t0) and t0 > 0 else None
    if sent is not None:
        lead = refresh or 16.67
        before = [x for x in samples if x["t"] <= sent - lead]
        samples = before[-1:] + [x for x in samples if x["t"] > sent - lead]
    return samples, sent, refresh


def _distance(a, b):
    return max((abs(x - y) for x, y in zip(a, b)), default=0.0) if len(a) == len(b) else float("inf")


def mover_path(points, ticks, commit):
    """One mover's path from the commit tick: its displacement series and how it broke the one-move rule.

    `points`: [(t, edges)] as split_scale_metrics.edges gives them; `ticks`: every tick's time, in order; `commit`:
    the index in `ticks` of the first tick whose layout differs. Returns {series: [points from its final edges, per
    tick from the commit], late, again, back: tick counts, px: the largest distance from the final edges in a tick
    that broke the rule}."""
    index = {t: i for i, t in enumerate(ticks)}
    final = points[-1][1]
    series = [None] * max(0, len(ticks) - commit)
    for t, value in points:
        i = index.get(t)
        if i is not None and i >= commit:
            d = _distance(value, final)
            series[i - commit] = None if d == float("inf") else round(d, 2)
    moved = []  # (tick index, distance from final before the step, went away from final)
    for (t0, v0), (t1, v1) in zip(points, points[1:]):
        i = index.get(t1)
        if i is None or i < commit:
            continue
        if len(v0) != len(v1):
            moved.append((i, 0.0, False))  # a row that changed its shape (a mover that came or went): one step
            continue
        if _distance(v0, v1) <= EPS:
            continue
        before, after = _distance(v0, final), _distance(v1, final)
        away = len(v1) == len(final) and any(abs(b - f) > abs(a - f) + EPS or (a - f) * (b - f) < -EPS * EPS
                                             for a, b, f in zip(v0, v1, final))  # farther, or past the final edge
        moved.append((i, before if before != float("inf") else 0.0, away and after > EPS))
    late = again = back = 0
    px = 0.0
    last, run = None, 0  # the last tick that moved; which of the mover's moves that tick is in (0: its first)
    late_start = bool(moved) and moved[0][0] > commit + LATE_TICKS
    for i, before, away in moved:
        if last is not None and i - last > GAP_TICKS + 1:
            run += 1
        last = i
        if run > 0:
            again += 1
        elif late_start:
            late += 1
        elif away:
            back += 1
        else:
            continue
        px = max(px, before)
    return {"series": series, "late": late, "again": again, "back": back, "px": round(px, 2)}


def content_offsets(samples):
    """{pane: [(t, the content's edges less its frame's edges: left, top, right, bottom)]} from pane rows."""
    out = {}
    for sample in samples:
        t = float(sample.get("t", 0))
        for row in sample.get("panes") or []:
            if not isinstance(row, list) or len(row) < PANE_ROW:
                continue
            fx, fy, fw, fh = (float(v) for v in row[PANE_FRAME])
            cx, cy, cw, ch = (float(v) for v in row[PANE_CONTENT])
            out.setdefault(str(row[0])[-6:], []).append(
                (t, (round(cx - fx, 2), round(cy - fy, 2), round(cx + cw - fx - fw, 2), round(cy + ch - fy - fh, 2))))
    return out


def content_off_pane(samples, commit_t):
    """(ticks, largest offset in points, {pane: ticks}): ticks from the commit on in which a pane's content is not at
    the offsets from its frame that it has in the trace's last tick (its rest)."""
    ticks, worst, per = set(), 0.0, {}
    for pane, points in content_offsets(samples).items():
        rest = points[-1][1]
        for t, offsets in points:
            if t < commit_t:
                continue
            d = _distance(offsets, rest)
            if d > EPS:
                ticks.add(t)
                per[pane] = per.get(pane, 0) + 1
                worst = max(worst, d)
    return len(ticks), round(worst, 2), per


def layout_stats(trace, sent_host_s=None):
    """The move's layout numbers from the trace (the module docstring's names); `aligned`: the trace had the input's
    time, so commit_ms and rest_ms count from the input."""
    samples, sent, refresh = _after_input(trace, sent_host_s)
    ticks = [s["t"] for s in samples]
    movers = {key: ssm.edges(key, points) for key, points in ssm.trace_movers(samples).items()}
    index = {t: i for i, t in enumerate(ticks)}
    first = last = None
    for points in movers.values():
        for (_, v0), (t1, v1) in zip(points, points[1:]):
            if len(v0) != len(v1) or _distance(v0, v1) > EPS:
                first = t1 if first is None else min(first, t1)
                last = t1 if last is None else max(last, t1)
    out = {"refresh_ms": refresh, "aligned": sent is not None, "ticks": len(ticks), "movers": len(movers)}
    if first is None:
        out.update({"commit_ms": None, "rest_ms": None, "frames_to_rest": None, "moved_after_commit": 0,
                    "moved_after_commit_frames": 0, "moved_after_commit_px": 0.0, "content_off_pane": 0,
                    "content_off_pane_px": 0.0, "broke": {}, "series": {}})
        return out
    commit = index[first]
    origin = sent if sent is not None else ticks[0]
    paths = {key: mover_path(points, ticks, commit) for key, points in movers.items()}
    broke = {key: {k: p[k] for k in ("late", "again", "back", "px")} for key, p in paths.items()
             if p["late"] or p["again"] or p["back"]}
    longest = sorted(paths, key=lambda k: -sum(1 for d in paths[k]["series"] if d))[:KEPT_SERIES]
    off, off_px, off_panes = content_off_pane(samples, first)
    out.update({
        "commit_ms": round(max(0.0, first - origin), 1), "rest_ms": round(max(0.0, last - origin), 1),
        "frames_to_rest": index[last] - commit,
        "moved_after_commit": len(broke),
        "moved_after_commit_frames": sum(b["late"] + b["again"] + b["back"] for b in broke.values()),
        "moved_after_commit_px": max((b["px"] for b in broke.values()), default=0.0),
        "content_off_pane": off, "content_off_pane_px": off_px, "content_off_panes": off_panes,
        "broke": broke, "series": {key: paths[key]["series"] for key in set(broke) | set(longest)},
    })
    return out


def pixel_stats(strip, tolerance=ssm.TOLERANCE):
    """pixel_after_commit (frames and ms) and pixel_reversals from a frame strip's frames."""
    rows = sorted((f for f in (strip or {}).get("frames") or [] if ssm._number(f.get("ms"))), key=lambda f: f["ms"])
    after = [f for f in rows if f["ms"] > 0]

    def off(f):
        return max(f.get("outside_vs_final") or 0, f.get("content_vs_final") or 0)

    def changed(f):
        return max(f.get("outside_vs_before") or 0, f.get("content_vs_before") or 0) > tolerance
    start = next((i for i, f in enumerate(after) if changed(f)), None)
    if start is None:
        return {"pixel_after_commit": 0, "pixel_after_commit_ms": 0.0, "pixel_reversals": 0, "pixel_series": []}
    moving = after[start:]
    end = max((i for i, f in enumerate(moving) if off(f) > tolerance), default=None)
    late = [f for f in moving[1:(end + 1 if end is not None else 1)]]
    reversals, low = 0, None
    for f in moving:
        share = off(f)
        if low is not None and share > low + PIXEL_RISE:
            reversals += 1
            low = share
        else:
            low = share if low is None else min(low, share)
    return {"pixel_after_commit": len(late),
            "pixel_after_commit_ms": round(moving[end]["ms"] - moving[0]["ms"], 1) if end else 0.0,
            "pixel_reversals": reversals, "pixel_series": [round(off(f), 4) for f in moving[:120]]}


def move(strip, trace, static=True, tabs_before=None, tabs_after=None, expected_new=0):
    """One move's record. `tabs_before` / `tabs_after`: the measured workspace's tab ids around the move;
    `expected_new`: tabs the move makes by design (a respawned source tab)."""
    base = ssm.transition(strip, trace, static=static)
    out = {key: base.get(key) for key in ("first_frame_ms", "settled_ms", "frame_p95_ms", "frame_max_ms",
                                          "dropped_frames", "blank_frames", "partial_frames", "retargets",
                                          "retargeted", "pixel_first_ms", "pixel_settled_ms", "error")}
    if trace and not trace.get("error"):
        out.update(layout_stats(trace, (strip or {}).get("sent_host_s")))
    if strip and not strip.get("error"):
        out.update(pixel_stats(strip))
    # A move inside one layout (a tab into another pane's strip) moves no rect: the pixels say that it happened.
    if out.get("error") and out.get("pixel_first_ms") is not None:
        rest = [part for part in str(out["error"]).split("; ") if part != "nothing moved after the input"]
        out["error"] = "; ".join(rest) or None
    out["reversals"] = (out.get("retargets") or 0) + (out.get("pixel_reversals") or 0)
    if tabs_before is not None and tabs_after is not None:
        made = [t for t in tabs_after if t not in set(tabs_before)]
        out["reloads"] = max(0, len(made) - expected_new)
        out["tabs_made"] = made
    else:
        out["reloads"] = None
    return out


def summarize(records):
    """A cell's move over its rounds: the median of each time, the worst round of each count; `rounds`, `failed`."""
    good = [r for r in records if not r.get("error")]
    out = {"rounds": len(records), "failed": len(records) - len(good),
           "errors": sorted({str(r["error"])[:200] for r in records if r.get("error")})}
    for key in SUMMARY_KEYS:
        values = [r[key] for r in good if ssm._number(r.get(key))]
        out[key] = None if not values else (max(values) if key in WORST else round(statistics.median(values), 1))
    out["refresh_ms"] = next((r.get("refresh_ms") for r in good if r.get("refresh_ms")), None)
    out["broke"] = sorted({f"{key}: {', '.join(f'{k} {v}' for k, v in how.items() if v)}"
                           for r in good for key, how in (r.get("broke") or {}).items()})[:12]
    return out


def verdict(summary, static=True):
    """{pass, failures}: a move passes with every judged count 0 (partial frames only for static content) and no
    failed round; a count that was not measured fails too, but for `reloads` and pixel counts of streaming content."""
    failures = []
    if not summary.get("rounds") or summary.get("failed"):
        failures.append(f"{summary.get('failed')} of {summary.get('rounds')} rounds failed")
    for key in JUDGED:
        if key == "partial_frames" and not static:
            continue
        value = summary.get(key)
        if value is None:
            if key != "reloads":
                failures.append(f"{key} not measured")
        elif value > 0:
            failures.append(f"{key} {value}")
    return {"pass": not failures, "failures": failures}


def _fmt(value, width):
    if value is None:
        return "-".rjust(width)
    return (f"{value:.1f}" if isinstance(value, float) else str(value)).rjust(width)


COLUMNS = (("commit ms", "commit_ms", 9), ("rest ms", "rest_ms", 8), ("frames", "frames_to_rest", 6),
           ("after#", "moved_after_commit_frames", 6), ("after px", "moved_after_commit_px", 8),
           ("off#", "content_off_pane", 5), ("off px", "content_off_pane_px", 7), ("rev", "reversals", 4),
           ("px-after ms", "pixel_after_commit_ms", 11), ("blank", "blank_frames", 5), ("partial", "partial_frames", 7),
           ("reload", "reloads", 6))


def table(report):
    """One line per cell and move: kind x shape x move, the numbers and pass/FAIL with the failing counts."""
    head = f"{'cell':<16} {'move':<22} " + " ".join(name.rjust(width) for name, _, width in COLUMNS) + "  verdict"
    lines = [head, "-" * len(head)]
    for cell in sorted(report.get("cells") or {}):
        for name, summary in (report["cells"][cell] or {}).items():
            judged = ((report.get("verdicts") or {}).get(cell) or {}).get(name) or {}
            mark = "pass" if judged.get("pass") else "FAIL " + "; ".join(judged.get("failures") or [])[:90]
            lines.append(f"{cell:<16} {name:<22} " + " ".join(_fmt(summary.get(key), width) for _, key, width in COLUMNS)
                         + "  " + mark)
    for cell, error in sorted((report.get("errors") or {}).items()):
        lines.append(f"{cell:<16} did not finish: {str(error)[:160]}")
    return "\n".join(lines)
