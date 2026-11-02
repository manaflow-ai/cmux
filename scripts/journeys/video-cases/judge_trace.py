#!/usr/bin/env python3
"""Per-frame geometry check of one layout motion (RESIZE VIDEOS suite).

  judge_trace.py TRACE.json [--frames MOVIE.frames.json] [--scale 2] [--json OUT.json]

TRACE.json: the reply of `debug.motion` `trace_stop` (keys `samples`, `refresh_ms`, `t0_s`), or a file holding
it under "trace". Each sample: `t` (ms from the first tick), `panes` rows [pane, x, y, w, h, alpha, z, fx, fy, fw,
fh, cw, ch, header, cx, cy, cw, ch] in window points (top-left origin), `dividers` rows [id, x, y, w, h, alpha, z].
MOVIE.frames.json (optional): `debug.motion` `record_*`'s per-frame list [[t_host_s, status, in_movie], ...].

It reports, with the frame number (the trace sample index, and the movie frame index when --frames is given):
  dropped    a display refresh with no new trace sample (or no new movie frame) while the layout moves
  off-grid   a pane edge that is not on a device pixel (x * scale not an integer)
  gap        two neighbouring panes further apart than at rest (more than 1 device pixel)
  overlap    two neighbouring panes closer than at rest (more than 1 device pixel); `overlap-fading` when one of
             them fades (a closing pane under its neighbour): reported, not counted as a defect
  reverse    an edge that moves back against its motion by more than 1 device pixel (overshoot, jump back)
  lurch      one frame's step more than 3x the steps around it (and over 2 device pixels): a jump on the curve
  end-jump   the last step into the rest frame more than 2x the step before it (and over 2 device pixels)
Standard library only. Exit 0 with no defect, 1 with a defect, 2 when the input has no motion.
"""
import argparse
import json
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


def judge(trace, frames=None, scale=2.0):
    samples = trace["samples"]
    refresh = float(trace.get("refresh_ms") or 8.33) or 8.33
    tol = TOL_PX / scale
    shown = [rects(s) for s in samples]
    # The motion: from the first sample whose rects differ from the one before to the last such sample.
    moving = [i for i in range(1, len(shown)) if shown[i] != shown[i - 1]]
    if not moving:
        return {"motion": None, "defects": [], "refresh_ms": refresh, "samples": len(samples)}
    first, last = moving[0], moving[-1]
    defects = []

    def add(kind, frame, what):
        defects.append({"kind": kind, "frame": frame, "t_ms": samples[frame].get("t"), "what": what})

    # dropped refreshes in the trace while it moves (and 2 refreshes either side)
    lo, hi = max(1, first - 2), min(len(samples) - 1, last + 2)
    for i in range(lo, hi + 1):
        dt = float(samples[i]["t"]) - float(samples[i - 1]["t"])
        missed = round(dt / refresh) - 1
        if missed >= 1:
            add("dropped", i, f"{dt:.2f} ms since the frame before: {missed} refresh(es) with no new frame")
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
    for pane in sorted(set(shown[first - 1]) & set(shown[last])):
        for name in ("left", "top", "right", "bottom"):
            series = [(i, edges(shown[i][pane])[name]) for i in range(first - 1, last + 1) if pane in shown[i]]
            steps = [(series[k][0], series[k][1] - series[k - 1][1]) for k in range(1, len(series))]
            total = series[-1][1] - series[0][1]
            if abs(total) <= tol:
                continue
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
            if len(mags) >= 2 and mags[-1] > 2 * max(mags[-2], 1e-9) and mags[-1] > 2 * tol * 2:
                add("end-jump", steps[-1][0], f"pane {pane} {name}: last step {steps[-1][1]:+.2f} pt, the one before "
                                              f"{steps[-2][1]:+.2f} pt")
    movie = None
    if frames:
        rows = [r for r in frames if isinstance(r, list) and r]
        t0 = float(trace.get("t0_s") or 0)
        lo_s = t0 + float(samples[first - 1]["t"]) / 1000 - 2 * refresh / 1000
        hi_s = t0 + float(samples[last]["t"]) / 1000 + 2 * refresh / 1000
        inside = [(k, float(r[0]), r[1] if len(r) > 1 else None) for k, r in enumerate(rows) if lo_s <= float(r[0]) <= hi_s]
        complete = [(k, t) for k, t, st in inside if st in (None, "complete", 0, "0")]
        for (k0, a), (k1, b) in zip(complete, complete[1:]):
            missed = round((b - a) * 1000 / refresh) - 1
            if missed >= 1:
                defects.append({"kind": "dropped", "frame": None, "movie_frame": k1, "t_ms": round((b - t0) * 1000, 2),
                                "what": f"movie: {(b - a) * 1000:.2f} ms between complete frames {k0} and {k1}: {missed} refresh(es) not composited"})
        movie = {"frames_in_motion": len(inside), "complete": len(complete)}
    counts = {}
    for d in defects:
        counts[d["kind"]] = counts.get(d["kind"], 0) + 1
    return {"motion": {"first_frame": first, "last_frame": last, "t_ms": [samples[first]["t"], samples[last]["t"]],
                       "frames": last - first + 1, "panes_at_rest": sorted(rest)},
            "refresh_ms": refresh, "samples": len(samples), "movie": movie, "counts": counts, "defects": defects}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace")
    ap.add_argument("--frames")
    ap.add_argument("--scale", type=float, default=2.0)
    ap.add_argument("--json")
    opts = ap.parse_args()
    trace = load_trace(opts.trace)
    frames = None
    if opts.frames:
        with open(opts.frames) as f:
            frames = json.load(f)
        if isinstance(frames, dict):
            frames = frames.get("frames") or []
    report = judge(trace, frames, opts.scale)
    if opts.json:
        with open(opts.json, "w") as f:
            json.dump(report, f, indent=1)
    if not report["motion"]:
        print("no motion in the trace")
        return 2
    m = report["motion"]
    print(f"motion: frames {m['first_frame']}..{m['last_frame']} ({m['frames']} frames, t {m['t_ms'][0]}..{m['t_ms'][1]} ms), "
          f"refresh {report['refresh_ms']} ms; defects: {report['counts'] or 'none'}")
    for d in report["defects"][:60]:
        where = f"frame {d['frame']}" if d.get("frame") is not None else f"movie frame {d.get('movie_frame')}"
        print(f"  {d['kind']:9} {where:16} t={d['t_ms']} ms  {d['what']}")
    if len(report["defects"]) > 60:
        print(f"  ... {len(report['defects']) - 60} more")
    return 1 if any(d["kind"] != "overlap-fading" for d in report["defects"]) else 0


if __name__ == "__main__":
    sys.exit(main())
