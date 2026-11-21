#!/usr/bin/env python3
"""Per-frame geometry check of one layout motion (RESIZE VIDEOS suite).

  judge_trace.py TRACE.json [--frames MOVIE.frames.json] [--scale 2] [--json OUT.json]
                [--events MOVIE.events.json] [--tiers diag-tiers.json]

TRACE.json: the reply of `debug.motion` `trace_stop` (keys `samples`, `refresh_ms`, `t0_s`), or a file holding
it under "trace". Each sample: `t` (ms from the first tick), `panes` rows [pane, x, y, w, h, alpha, z, fx, fy, fw,
fh, cw, ch, header, cx, cy, cw, ch] in window points (top-left origin), `dividers` rows [id, x, y, w, h, alpha, z].
MOVIE.frames.json (optional): `debug.motion` `record_*`'s per-frame list [[t_host_s, status, in_movie], ...].

One motion per drag (VIDEO JUDGE, STATUS 8124/8130): with the recording's events (--events, or BASE.events.json beside
BASE.trace.json), the film is cut at each drag's start and each part is judged as its own motion, so two opposite drags
are not one motion whose first drag moves "against its motion" (rkd-col-drag-clamp: 28 false "reverse"). A drag starts
at its HID t_sent moved to the host clock by the entry's own host_offset_s (ext_video, #32776) when every HID drag has
one, else at the app input journal's mouse-down (uptimeNanos, the trace's clock). With no drag, the whole film is one
motion, as before; when the events have HID drags that nothing places on the trace's clock (no host_offset_s, no
journal), the report's `notes` says the film is not split. Drags that start at the same sample (several before the
trace starts) cut once, and the part is labelled with the last of them. Each trace interval and film-frame interval is
judged by the part whose motion window (the motion and 2 refreshes either side) holds it; when two close drags' windows
both hold it, by the part whose span (from its cut to the next cut) holds it: a drop between two close drags counts
once, and none is lost. Film windows that overlap join, so a film stall across the cut between two drags is judged too
(by the part that holds its later frame). Film frames are paired in time order. The report's `motions` has one entry per part (its input, motion and each pane edge's travel); `motion` spans them all. Each defect of a split film has
`drag`, the index (in the sorted drag starts) of the drag that starts its part.

It reports, with the frame number (the trace sample index, and the movie frame index when --frames is given):
  dropped    a display refresh with no new trace sample (or no new movie frame) while the layout moves
  off-grid   a pane edge that is not on a device pixel (x * scale not an integer)
  gap        two neighbouring panes further apart than at rest (more than 1 device pixel)
  overlap    two neighbouring panes closer than at rest (more than 1 device pixel); `overlap-fading` when one of
             them fades (a closing pane under its neighbour): reported, not counted as a defect
  reverse    an edge that moves back against its motion by more than 1 device pixel (overshoot, jump back)
  lurch      one frame's step more than 3x the steps around it (and over 2 device pixels): a jump on the curve
  end-jump   the last step into the rest frame more than 2x the last moving step before it, or the edge's only step
             (still before it), over 2 device pixels
With --tiers (ext_tiers: the app main thread's cumulative CPU ms per core tier, CLOCK_UPTIME_RAW) and --events (the
recording's app input journal, uptimeNanos on the same clock), each refresh interval of the motion gets the tier its main
thread ran on most (Super, Performance, Efficiency), so dropped refreshes are counted per tier, and each input (key-down,
mouse-down) gets its start tier, the tier with the most main CPU in its first 4 ms (as judge_keys.py): a drag on a
mini compares with a drag on another Mac only within one tier (STATUS 7770: a main thread woken from idle starts on E).
Standard library only. Exit 0 with no defect, 1 with a defect, 2 when the input has no motion.
"""
import argparse
import json
import os
import sys

TOL_PX = 1.0  # device pixels


def load_trace(path):
    with open(path) as f:
        data = json.load(f)
    for key in ("trace", "result", "value"):
        if isinstance(data, dict) and "samples" not in data and isinstance(data.get(key), dict):
            data = data[key]
    if not isinstance(data, dict) or not isinstance(data.get("samples"), list):
        sys.exit(f"{path}: no trace samples")
    return data


def rects(sample):
    """{pane: (x, y, w, h, alpha)} of the panes shown in this sample."""
    out = {}
    for row in sample.get("panes") or []:
        if isinstance(row, list) and len(row) >= 6:
            out[str(row[0])] = tuple(float(v) for v in row[1:6])
    return out


def edges(r):
    x, y, w, h, _ = r
    return {"left": x, "top": y, "right": x + w, "bottom": y + h}


def neighbours(rest):
    """Pairs (a, b, axis) of panes that touch side by side (axis x: b right of a) or stacked (axis y) at rest."""
    pairs = []
    names = sorted(rest)
    for a in names:
        for b in names:
            if a == b:
                continue
            ra, rb = rest[a], rest[b]
            gx = rb[0] - (ra[0] + ra[2])
            oy = min(ra[1] + ra[3], rb[1] + rb[3]) - max(ra[1], rb[1])
            if -2 <= gx <= 24 and oy > 0.5 * min(ra[3], rb[3]):
                pairs.append((a, b, "x", gx))
            gy = rb[1] - (ra[1] + ra[3])
            ox = min(ra[0] + ra[2], rb[0] + rb[2]) - max(ra[0], rb[0])
            if -2 <= gy <= 24 and ox > 0.5 * min(ra[2], rb[2]):
                pairs.append((a, b, "y", gy))
    return pairs


DRAG_MARGIN_MS = 2.0  # a part starts this long before its drag's start (clock read jitter)


def drag_starts(trace, events):
    """(ms after t0_s of each drag's start, sorted; source) from the recording's events, or ([], None) with no drag.
    HID drags with host_offset_s (all of them): t_sent on the host clock. Else the journal's mouse-downs."""
    if not isinstance(events, dict):
        return [], None
    t0 = float(trace.get("t0_s") or 0)
    drags = [h for h in events.get("hid") or [] if isinstance(h, dict) and h.get("kind") == "drag"]
    if drags and all(isinstance(h.get("host_offset_s"), (int, float)) and isinstance(h.get("t_sent"), (int, float))
                     for h in drags):
        return sorted((float(h["t_sent"]) + float(h["host_offset_s"]) - t0) * 1000 for h in drags), "hid"
    downs = []
    for e in events.get("journal") or []:
        kind = e.get("kind") or {}
        body = (kind.get("mouse") or {}).get("_0") if isinstance(kind, dict) else None
        if isinstance(body, dict) and body.get("phase") == "down" and e.get("uptimeNanos"):
            downs.append((float(e["uptimeNanos"]) / 1e9 - t0) * 1000)
    return (sorted(downs), "journal") if downs else ([], None)


def unsplit_note(events):
    """Why a film whose events have drags is not split, or None. HID drags with no host_offset_s (rounds before
    #32776) are on the driver's clock; without the journal's mouse-downs nothing places them on the trace's clock."""
    if not isinstance(events, dict):
        return None
    drags = [h for h in events.get("hid") or [] if isinstance(h, dict) and h.get("kind") == "drag"]
    if not drags:
        return None
    missing = sum(1 for h in drags if not (isinstance(h.get("host_offset_s"), (int, float))
                                           and isinstance(h.get("t_sent"), (int, float))))
    return (f"{len(drags)} HID drag(s), {missing} of them with no host_offset_s or no t_sent, and no mouse-down in the "
            "app journal: "
            "nothing places them "
            "on the trace's clock, so the film is not split and is judged as one motion (two opposite drags then show "
            "as 'reverse' on the first one)")


def judge_motion(samples, shown, first, last, tol, scale, add):
    """The geometry checks of one motion (samples first..last move; first - 1 is the rest before it, last the rest
    after it). Returns (panes at rest, {pane: {edge: travel pt}})."""
    # every shown pane edge on a device pixel
    for i in range(first - 1, last + 1):
        for pane, r in shown[i].items():
            for name, v in edges(r).items():
                off = abs(v * scale - round(v * scale))
                if off > 0.01:
                    add("off-grid", i, f"pane {pane} {name} at {v:.2f} pt = {v * scale:.2f} device px")
    # neighbours: the space between them as at rest
    rest = {p: r for p, r in shown[last].items() if r[4] >= 0.999}
    zoomed = {z for smp in samples[first - 1:last + 1] for z in (smp.get("zoom") or []) if z}
    for a, b, axis, at_rest in neighbours(rest):
        for i in range(first, last + 1):
            ra, rb = shown[i].get(a), shown[i].get(b)
            if not ra or not rb or ra[4] < 0.999 or rb[4] < 0.999 or (zoomed & {a, b}):
                continue  # a zoom's pane covers the others on purpose
            # A pane still shown between them this frame (the closing one, a new one): judge the chain a..x..b.
            lo_k, hi_k = (0, 2) if axis == "x" else (1, 3)
            start, end = ra[lo_k] + ra[hi_k], rb[lo_k]
            # ...that also faces both on the other axis (a pane of another row or column is not between them).
            ox, oxl = (1, 3) if axis == "x" else (0, 2)
            def faces(r, q):
                return min(r[ox] + r[oxl], q[ox] + q[oxl]) - max(r[ox], q[ox]) > 0.5 * min(r[oxl], q[oxl])
            between = sorted((r[lo_k], p, r) for p, r in shown[i].items()
                             if p not in (a, b) and r[lo_k] < end and r[lo_k] + r[hi_k] > start and r[hi_k] > 0
                             and faces(r, ra) and faces(r, rb))
            chain = [(a, ra)] + [(p, r) for _, p, r in between] + [(b, rb)]
            for (pa, qa), (pb, qb) in zip(chain, chain[1:]):
                gap = qb[lo_k] - (qa[lo_k] + qa[hi_k])
                fading = qa[4] < 0.999 or qb[4] < 0.999
                if gap - at_rest > tol:
                    add("gap", i, f"{pa}|{pb} ({axis}): {gap:.2f} pt apart, {at_rest:.2f} at rest")
                elif at_rest - gap > tol:
                    add("overlap-fading" if fading else "overlap", i,
                        f"{pa}|{pb} ({axis}): {gap:.2f} pt apart, {at_rest:.2f} at rest" + (" (one of them fades)" if fading else ""))
    # each edge of each pane that is shown from the start to the rest frame: reversals, lurches, the end jump
    travel = {}
    for pane in sorted(set(shown[first - 1]) & set(shown[last])):
        for name in ("left", "top", "right", "bottom"):
            series = [(i, edges(shown[i][pane])[name]) for i in range(first - 1, last + 1) if pane in shown[i]]
            steps = [(series[k][0], series[k][1] - series[k - 1][1]) for k in range(1, len(series))]
            total = series[-1][1] - series[0][1]
            if abs(total) <= tol:
                continue
            travel.setdefault(pane, {})[name] = round(total, 3)
            sign = 1 if total > 0 else -1
            for frame, d in steps:
                if d * sign < -tol:
                    add("reverse", frame, f"pane {pane} {name} moved {d:+.2f} pt against its motion ({total:+.2f} pt in all)")
            mags = [abs(d) for _, d in steps]
            for k, (frame, d) in enumerate(steps):
                around = [m for m in mags[max(0, k - 2):k] + mags[k + 1:k + 3] if m > 0]
                if around and abs(d) > 3 * (sum(around) / len(around)) and abs(d) > 2 * tol * 2:
                    add("lurch", frame, f"pane {pane} {name} stepped {d:+.2f} pt; the steps around it average "
                                        f"{sum(around) / len(around):.2f} pt")
            # The step before the last that moved: a refresh with no new drag input (a slow or sparse drag) is a 0 step,
            # not a smaller step (rkd-col-drag-2's fast drag back: 12.5, 0, 12.5 pt).
            before = next((d for _, d in reversed(steps[:-1]) if abs(d) > 0), None)
            if len(mags) >= 2 and mags[-1] > 2 * tol * 2:
                if before is None:
                    # Still for the whole motion, then all its travel in the last step: a snap into the rest frame.
                    add("end-jump", steps[-1][0], f"pane {pane} {name}: last step {steps[-1][1]:+.2f} pt, still in the "
                                                  f"{len(mags) - 1} step(s) before it")
                elif mags[-1] > 2 * abs(before):
                    add("end-jump", steps[-1][0], f"pane {pane} {name}: last step {steps[-1][1]:+.2f} pt, the last "
                                                  f"moving step before it {before:+.2f} pt")
    return sorted(rest), travel


def judge(trace, frames=None, scale=2.0, events=None):
    samples = trace["samples"]
    refresh = float(trace.get("refresh_ms") or 8.33) or 8.33
    tol = TOL_PX / scale
    shown = [rects(s) for s in samples]
    # A motion: from the first sample whose rects differ from the one before to the last such sample, per part.
    moving = [i for i in range(1, len(shown)) if shown[i] != shown[i - 1]]
    if not moving:
        return {"motion": None, "motions": [], "defects": [], "refresh_ms": refresh, "samples": len(samples),
                "notes": []}
    starts, source = drag_starts(trace, events)
    notes = []
    if not source and unsplit_note(events):
        notes.append(unsplit_note(events))
    # Part k runs from drag k's start to drag k+1's; samples before the first drag are a part of their own. Drags
    # that start at the same sample (several before the trace starts) cut once: the part is the last one's.
    cut_of = [next((i for i, s in enumerate(samples) if float(s["t"]) >= t - DRAG_MARGIN_MS), len(samples))
              for t in starts]
    drag_at = {c: j for j, c in enumerate(cut_of)}  # starts are sorted: the last drag at each cut wins
    bounds = [0] + sorted(c for c in drag_at if c > 0) + [len(samples)]
    parts = []
    for lo, hi in zip(bounds, bounds[1:]):
        inside = [i for i in moving if lo <= i < hi]
        drag = drag_at.get(lo)
        if inside or drag is not None:
            parts.append((drag, inside, lo, hi))
    defects, motions = [], []
    t0 = float(trace.get("t0_s") or 0)
    rows = [r for r in (frames or []) if isinstance(r, list) and r]
    host = lambda i: t0 + float(samples[i]["t"]) / 1000  # noqa: E731
    # Each part's motion window, as for a whole film before the split: trace intervals into samples
    # first-2 .. last+2, film frames within 2 refreshes of the motion's samples.
    windows = []
    for drag, inside, part_lo, part_hi in parts:
        if inside:
            first, last = inside[0], inside[-1]
            windows.append(((max(1, first - 2), min(len(samples) - 1, last + 2)),
                            (host(first - 1) - 2 * refresh / 1000, host(last) + 2 * refresh / 1000)))
        else:
            windows.append(None)
    # An interval (into trace sample i, or between two film frames by the later one) is judged by the part whose
    # window holds it. When two close drags' windows both hold it, it goes to the part whose own span (from its cut
    # to the next cut) holds it, else to the earlier part: each is counted once, and none that a window holds is lost.
    def owner(holders, own):
        return own if own in holders else (holders[0] if holders else None)
    def part_of_sample(i):
        return next((k for k, (_, _, lo, hi) in enumerate(parts) if lo <= i < hi), None)
    def part_of_time(t):
        k = None
        for j, (_, _, lo, _) in enumerate(parts):
            # A drag after the trace ends cuts at len(samples): its part holds no sample and no time.
            if lo < len(samples) and (lo == 0 or t >= host(lo)):
                k = j
        return k
    trace_owner = {}
    for i in range(1, len(samples)):
        holders = [k for k, w in enumerate(windows) if w and w[0][0] <= i <= w[0][1]]
        if holders:
            trace_owner[i] = owner(holders, part_of_sample(i))
    complete_rows = sorted(((k, float(r[0])) for k, r in enumerate(rows)
                            if (r[1] if len(r) > 1 else None) in (None, "complete", 0, "0")), key=lambda kt: kt[1])
    def in_movie_window(k, t):
        return windows[k] is not None and windows[k][1][0] <= t <= windows[k][1][1]
    row_owner = {}
    for k, r in enumerate(rows):
        t = float(r[0])
        holders = [j for j in range(len(parts)) if in_movie_window(j, t)]
        if holders:
            row_owner[k] = owner(holders, part_of_time(t))
    # Movie windows that overlap form one span of motion (two adjacent drags overlap at their cut). A pair of complete
    # frames is judged when one such span holds both frames, as a whole film's window would: a stall across the cut
    # between two drags has one frame in each window. It goes to the part that holds its later frame.
    spans = []
    for j in sorted((j for j, w in enumerate(windows) if w), key=lambda j: windows[j][1][0]):
        lo_s, hi_s = windows[j][1]
        if spans and lo_s <= spans[-1][1]:
            spans[-1] = (spans[-1][0], max(spans[-1][1], hi_s), spans[-1][2] + [j])
        else:
            spans.append((lo_s, hi_s, [j]))
    pair_owner = {}
    for (k0, a), (k1, b) in zip(complete_rows, complete_rows[1:]):
        span = next((sp for sp in spans if sp[0] <= a and b <= sp[1]), None)
        if span is None:
            continue
        holders = [j for j in span[2] if in_movie_window(j, b)] or [j for j in span[2] if in_movie_window(j, a)]
        pair_owner[k1] = (k0, a, b, owner(holders, part_of_time(b)))
    for n, (drag, inside, part_lo, part_hi) in enumerate(parts):
        entry = {"input": None if drag is None else {"drag": drag, "t_ms": round(starts[drag], 2), "source": source},
                 "motion": None}
        motions.append(entry)
        if not inside:
            continue
        first, last = inside[0], inside[-1]
        def add(kind, frame, what, drag=drag):
            d = {"kind": kind, "frame": frame, "t_ms": samples[frame].get("t"), "what": what}
            if source:
                d["drag"] = drag
            defects.append(d)
        # dropped refreshes in the trace while it moves (and 2 refreshes either side)
        for i in sorted(i for i, k in trace_owner.items() if k == n):
            dt = float(samples[i]["t"]) - float(samples[i - 1]["t"])
            missed = round(dt / refresh) - 1
            if missed >= 1:
                add("dropped", i, f"{dt:.2f} ms since the frame before: {missed} refresh(es) with no new frame")
        rest, travel = judge_motion(samples, shown, first, last, tol, scale, add)
        entry["motion"] = {"first_frame": first, "last_frame": last, "t_ms": [samples[first]["t"], samples[last]["t"]],
                           "frames": last - first + 1, "panes_at_rest": rest}
        entry["travel"] = travel
        if rows:
            for k1, (k0, a, b, k) in sorted(pair_owner.items()):
                if k != n:
                    continue
                missed = round((b - a) * 1000 / refresh) - 1
                if missed >= 1:
                    d = {"kind": "dropped", "frame": None, "movie_frame": k1, "t_ms": round((b - t0) * 1000, 2),
                         "what": f"movie: {(b - a) * 1000:.2f} ms between complete frames {k0} and {k1}: {missed} refresh(es) not composited"}
                    if source:
                        d["drag"] = drag
                    defects.append(d)
            mine = [k for k, j in row_owner.items() if j == n]
            entry["movie"] = {"frames_in_motion": len(mine),
                              "complete": sum(1 for k in mine if (rows[k][1] if len(rows[k]) > 1 else None) in (None, "complete", 0, "0"))}
    judged = [m["motion"] for m in motions if m["motion"]]
    first, last = judged[0]["first_frame"], judged[-1]["last_frame"]
    movie = None
    if rows:
        movie = {"frames_in_motion": sum(m.get("movie", {}).get("frames_in_motion", 0) for m in motions),
                 "complete": sum(m.get("movie", {}).get("complete", 0) for m in motions)}
    counts = {}
    for d in defects:
        counts[d["kind"]] = counts.get(d["kind"], 0) + 1
    return {"motion": {"first_frame": first, "last_frame": last, "t_ms": [samples[first]["t"], samples[last]["t"]],
                       "frames": last - first + 1, "panes_at_rest": judged[-1]["panes_at_rest"]},
            "motions": motions, "split": source, "notes": notes,
            "refresh_ms": refresh, "samples": len(samples), "movie": movie, "counts": counts, "defects": defects}


def tier_split(rows, a_ns, b_ns, n):
    def at(t):
        best = rows[0]
        for r in rows:
            if r[0] > t:
                break
            best = r
        return best
    ra, rb = at(a_ns), at(b_ns)
    return [rb[1 + i] - ra[1 + i] for i in range(n)]


def tiers_report(trace, report, tiers, events):
    """Per-tier refresh intervals and dropped refreshes of the motion, and the start tier of each input."""
    rows, levels = tiers.get("rows") or [], tiers.get("levels") or []
    n = len(levels)
    if len(rows) < 2 or not n or not report.get("motion"):
        return None
    names = [str(x)[:1] for x in levels]
    samples, refresh = trace["samples"], float(report["refresh_ms"])
    t0_ns = float(trace.get("t0_s") or 0) * 1e9
    ns = lambda t_ms: int(t0_ns + float(t_ms) * 1e6)
    spans = [(m["motion"]["first_frame"], m["motion"]["last_frame"]) for m in report.get("motions") or [] if m["motion"]]
    spans = spans or [(report["motion"]["first_frame"], report["motion"]["last_frame"])]
    intervals = sorted({i for first, last in spans for i in range(max(1, first - 2), min(len(samples) - 1, last + 2) + 1)})
    per = {k: {"intervals": 0, "dropped": 0, "cpu_ms": 0.0} for k in names + ["idle"]}
    for i in intervals:
        a, b = ns(samples[i - 1]["t"]), ns(samples[i]["t"])
        if a < rows[0][0] or b > rows[-1][0]:
            continue
        cpu = tier_split(rows, a, b, n)
        k = names[max(range(n), key=lambda j: cpu[j])] if sum(cpu) > 0.05 else "idle"
        missed = max(0, round((float(samples[i]["t"]) - float(samples[i - 1]["t"])) / refresh) - 1)
        per[k]["intervals"] += 1
        per[k]["dropped"] += missed
        per[k]["cpu_ms"] = round(per[k]["cpu_ms"] + sum(cpu), 2)
    inputs = []
    for e in (events or {}).get("journal") or []:
        kind = e.get("kind") or {}
        name = next(iter(kind), None) if isinstance(kind, dict) else None
        body = (kind.get(name) or {}).get("_0") if name else None
        if not isinstance(body, dict) or body.get("phase") != "down" or not e.get("uptimeNanos") or body.get("keyClass") == "modifier":
            continue
        t = int(e["uptimeNanos"])
        if not (rows[0][0] <= t - 2_000_000 and rows[-1][0] >= t + 4_000_000):
            continue
        first4 = tier_split(rows, t - 2_000_000, t + 4_000_000, n)
        inputs.append({"input": name, "t_ms": round((t - t0_ns) / 1e6, 2),
                       "start_tier": names[max(range(n), key=lambda j: first4[j])] if sum(first4) > 0.05 else "idle",
                       "first_4ms_cpu": dict(zip(names, [round(x, 2) for x in first4]))})
    return {"levels": levels, "per_tier": {k: v for k, v in per.items() if v["intervals"]}, "inputs": inputs}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace")
    ap.add_argument("--frames")
    ap.add_argument("--scale", type=float, default=2.0)
    ap.add_argument("--json")
    ap.add_argument("--tiers")
    ap.add_argument("--events")
    opts = ap.parse_args()
    trace = load_trace(opts.trace)
    frames = None
    if opts.frames:
        with open(opts.frames) as f:
            frames = json.load(f)
        if isinstance(frames, dict):
            frames = frames.get("frames") or []
    events_path = opts.events
    if not events_path and opts.trace.endswith(".trace.json"):
        beside = opts.trace[: -len(".trace.json")] + ".events.json"
        events_path = beside if os.path.isfile(beside) else None
    events = None
    if events_path:
        with open(events_path) as f:
            events = json.load(f)
    report = judge(trace, frames, opts.scale, events)
    if opts.tiers:
        with open(opts.tiers) as f:
            tiers = json.load(f)
        report["tiers"] = tiers_report(trace, report, tiers, events)
    if opts.json:
        with open(opts.json, "w") as f:
            json.dump(report, f, indent=1)
    if not report["motion"]:
        print("no motion in the trace")
        return 2
    m = report["motion"]
    print(f"motion: frames {m['first_frame']}..{m['last_frame']} ({m['frames']} frames, t {m['t_ms'][0]}..{m['t_ms'][1]} ms), "
          f"refresh {report['refresh_ms']} ms; defects: {report['counts'] or 'none'}")
    if report.get("split"):
        for k, part in enumerate(report["motions"]):
            pm, inp = part["motion"], part["input"]
            n = sum(1 for d in report["defects"] if d.get("drag") == (inp or {}).get("drag"))
            where = f"drag {inp['drag']} at {inp['t_ms']} ms ({inp['source']})" if inp else "before the first drag"
            print(f"  part {k}, {where}: " + (f"frames {pm['first_frame']}..{pm['last_frame']}, {n} defect(s)" if pm else "no motion"))
    else:
        print("  one motion: " + (report["notes"][0] if report.get("notes") else
                                  "no drag in the events (or no events), the film is not split"))
    if report.get("tiers"):
        t = report["tiers"]
        print("  per tier (refresh intervals, dropped): " + ", ".join(f"{k} {v['intervals']}/{v['dropped']}" for k, v in t["per_tier"].items())
              + "; inputs: " + ", ".join(f"{i['input']}@{i['t_ms']} {i['start_tier']}" for i in t["inputs"]))
    for d in report["defects"][:60]:
        where = f"frame {d['frame']}" if d.get("frame") is not None else f"movie frame {d.get('movie_frame')}"
        print(f"  {d['kind']:9} {where:16} t={d['t_ms']} ms  {d['what']}")
    if len(report["defects"]) > 60:
        print(f"  ... {len(report['defects']) - 60} more")
    return 1 if any(d["kind"] != "overlap-fading" for d in report["defects"]) else 0


if __name__ == "__main__":
    sys.exit(main())
