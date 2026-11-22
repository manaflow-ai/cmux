#!/usr/bin/env python3
"""Measure one mobile flow clip frame by frame.

    measure.py CLIP_DIR [--flows flows.json] [--json]

CLIP_DIR holds clip.mp4 and meta.json (README.md, "Clip contract"). Prints the
flow's numbers and writes CLIP_DIR/result.json:

  response_ms   stimulus to the first frame that changes in the flow's region; a
                change counts when the region's mean changes by CHANGE or any
                TILE x TILE block of it by TILE_CHANGE (one new glyph is a few
                pixels: a region-wide mean alone never sees it). For flows with
                `response_after_stimulus_change` (send to first token, offline
                error) the first burst after the stimulus is the app's own send
                feedback (the user's bubble, a button state); it is reported as
                feedback_ms and the response is the first change after it
  settle_ms     stimulus to the last change before 300 ms of stillness
  motion_ms     settle_ms - response_ms (the animation's length)
  frames        frames the screen drew between response and settle
  dropped       frame slots missed while moving: the recorder writes a frame
                only when the screen changes, so a gap of k frame periods
                inside the motion is k-1 dropped frames when the next frame
                catches up (moves further than the one before the gap)
  worst_gap_ms  the longest gap between drawn frames while moving
  jumps         frames where the moving edge moved more than 2% of the screen
                at over 3x the speed of the frames around it (a layout jump)
  bursts        separate bursts of change after the response (1 is one
                animation; more means the layout settled, then moved again:
                pop-in)
  curve         for flows with an `edge`: the edge's displacement over time,
                fitted to a damped spring (SwiftUI's response and
                dampingFraction, the same numbers as
                .spring(response:dampingFraction:)), plus overshoot and the
                time to 90% of the travel
  stream        for streaming flows: updates per second and the median gap
                between text updates

Only the standard library and ffmpeg (PATH, $MOBILE_BENCH_FFMPEG, or
imageio-ffmpeg's bundled binary) are needed, so it runs on any fleet host.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
WIDTH = 120  # analysis width in pixels; height keeps the aspect ratio
CHANGE = 1.2  # mean absolute luma change (0-255) per pixel that counts as a change
TILE = 6  # block size (analysis pixels) of the local change check
TILE_CHANGE = 4.0  # mean absolute luma change in one block that counts as a change (a glyph)
STILL_MS = 300.0  # stillness that ends a flow
FEEDBACK_STILL_MS = 150.0  # stillness that ends the send feedback burst


def ffmpeg_bin() -> str:
    env = os.environ.get("MOBILE_BENCH_FFMPEG")
    if env:
        return env
    found = shutil.which("ffmpeg")
    if found:
        return found
    try:
        import imageio_ffmpeg  # type: ignore

        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:  # noqa: BLE001
        sys.exit("measure.py: no ffmpeg (install it, or set MOBILE_BENCH_FFMPEG)")


def decode(clip: Path) -> tuple[int, int, list[float], list[bytes]]:
    """Grayscale frames at WIDTH wide, with their presentation times (s)."""
    ff = ffmpeg_bin()
    probe = subprocess.run([ff, "-hide_banner", "-i", str(clip)], capture_output=True, text=True)
    m = re.search(r"Video:.*?(\d{2,5})x(\d{2,5})", probe.stderr)
    if not m:
        sys.exit(f"measure.py: no video stream in {clip}")
    w0, h0 = int(m.group(1)), int(m.group(2))
    h = max(2, round(h0 * WIDTH / w0 / 2) * 2)
    cmd = [ff, "-hide_banner", "-loglevel", "info", "-i", str(clip), "-an",
           "-vf", f"scale={WIDTH}:{h}:flags=area,format=gray,showinfo",
           "-fps_mode", "passthrough", "-f", "rawvideo", "-"]
    proc = subprocess.run(cmd, capture_output=True)
    if proc.returncode != 0:
        sys.exit(f"measure.py: ffmpeg failed on {clip}: {proc.stderr[-400:]!r}")
    pts = [float(x) for x in re.findall(rb"pts_time:\s*([0-9.]+)", proc.stderr)]
    size = WIDTH * h
    raw = proc.stdout
    frames = [raw[i:i + size] for i in range(0, len(raw) - size + 1, size)]
    n = min(len(frames), len(pts))
    return WIDTH, h, pts[:n], frames[:n]


def region_rows(h: int, region: list[float]) -> tuple[int, int]:
    top = max(0, min(h - 1, int(region[0] * h)))
    bottom = max(top + 1, min(h, int(round(region[1] * h))))
    return top, bottom


def frame_diff(a: bytes, b: bytes, w: int, top: int, bottom: int) -> float:
    lo, hi = top * w, bottom * w
    total = sum(abs(x - y) for x, y in zip(a[lo:hi], b[lo:hi]))
    return total / max(1, hi - lo)


def tile_diff(a: bytes, b: bytes, w: int, top: int, bottom: int) -> float:
    """The largest mean absolute change of any TILE x TILE block in rows top..bottom."""
    cols = (w + TILE - 1) // TILE
    worst = 0.0
    for r0 in range(top, bottom, TILE):
        r1 = min(bottom, r0 + TILE)
        sums = [0] * cols
        for r in range(r0, r1):
            lo = r * w
            ra, rb = a[lo:lo + w], b[lo:lo + w]
            if ra == rb:
                continue
            for c in range(w):
                d = ra[c] - rb[c]
                if d:
                    sums[c // TILE] += d if d > 0 else -d
        for k, tot in enumerate(sums):
            if tot:
                area = (r1 - r0) * (min(w, (k + 1) * TILE) - k * TILE)
                worst = max(worst, tot / area)
    return worst


def row_profile(f: bytes, w: int, top: int, bottom: int) -> list[float]:
    return [sum(f[r * w:(r + 1) * w]) / w for r in range(top, bottom)]


def col_profile(f: bytes, w: int, top: int, bottom: int) -> list[float]:
    rows = bottom - top
    return [sum(f[r * w + c] for r in range(top, bottom)) / rows for c in range(w)]


def best_shift(ref: list[float], cur: list[float], max_shift: int) -> int:
    """The shift s minimising mean |cur[i] - ref[i - s]| (content moved by s)."""
    n = len(ref)
    best, best_err = 0, float("inf")
    for s in range(-max_shift, max_shift + 1):
        lo, hi = max(0, s), min(n, n + s)
        if hi - lo < n // 4:
            continue
        err = sum(abs(cur[i] - ref[i - s]) for i in range(lo, hi)) / (hi - lo)
        if err < best_err:
            best, best_err = s, err
    return best


def track_edge(frames, w, h, top, bottom, i0, i1, edge):
    """Displacement (pixels at analysis scale) of the region's content per frame,
    relative to frame i0, by matching each frame's profile to the previous one and
    summing the steps (so motions longer than the search window still track)."""
    horizontal = edge == "horizontal"
    prof = (lambda f: col_profile(f, w, top, bottom)) if horizontal else (lambda f: row_profile(f, w, top, bottom))
    span = w if horizontal else bottom - top
    max_step = max(4, span // 3)
    pos, out = 0.0, [0.0]
    prev = prof(frames[i0])
    for i in range(i0 + 1, i1 + 1):
        cur = prof(frames[i])
        pos += best_shift(prev, cur, max_step)
        out.append(pos)
        prev = cur
    return out, span


def spring(t: float, response: float, damping: float) -> float:
    """Progress 0..1 of SwiftUI's .spring(response:dampingFraction:) from rest."""
    w0 = 2 * math.pi / max(response, 1e-4)
    z = damping
    if z < 1:
        wd = w0 * math.sqrt(1 - z * z)
        return 1 - math.exp(-z * w0 * t) * (math.cos(wd * t) + z * w0 / wd * math.sin(wd * t))
    if z == 1:
        return 1 - (1 + w0 * t) * math.exp(-w0 * t)
    r1 = -w0 * (z - math.sqrt(z * z - 1))
    r2 = -w0 * (z + math.sqrt(z * z - 1))
    return 1 - (r2 * math.exp(r1 * t) - r1 * math.exp(r2 * t)) / (r2 - r1)


def nelder_mead(f, x0, step, iters=400):
    n = len(x0)
    pts = [list(x0)] + [[x0[j] + (step[j] if j == i else 0) for j in range(n)] for i in range(n)]
    vals = [f(p) for p in pts]
    for _ in range(iters):
        order = sorted(range(n + 1), key=lambda k: vals[k])
        pts, vals = [pts[k] for k in order], [vals[k] for k in order]
        cen = [sum(p[j] for p in pts[:-1]) / n for j in range(n)]
        refl = [cen[j] + (cen[j] - pts[-1][j]) for j in range(n)]
        fr = f(refl)
        if fr < vals[0]:
            exp = [cen[j] + 2 * (cen[j] - pts[-1][j]) for j in range(n)]
            fe = f(exp)
            pts[-1], vals[-1] = (exp, fe) if fe < fr else (refl, fr)
        elif fr < vals[-2]:
            pts[-1], vals[-1] = refl, fr
        else:
            con = [cen[j] + 0.5 * (pts[-1][j] - cen[j]) for j in range(n)]
            fc = f(con)
            if fc < vals[-1]:
                pts[-1], vals[-1] = con, fc
            else:
                for k in range(1, n + 1):
                    pts[k] = [pts[0][j] + 0.5 * (pts[k][j] - pts[0][j]) for j in range(n)]
                    vals[k] = f(pts[k])
        if max(vals) - min(vals) < 1e-9:
            break
    k = min(range(n + 1), key=lambda i: vals[i])
    return pts[k], vals[k]


def fit_curve(ts: list[float], disp: list[float], span: int) -> dict | None:
    travel = disp[-1] - disp[0]
    if abs(travel) < max(2.0, 0.02 * span):
        return None
    prog = [(d - disp[0]) / travel for d in disp]
    t0 = ts[0]
    rel = [t - t0 for t in ts]

    def err(p):
        resp, damp, lag = p
        if resp <= 0.02 or resp > 3 or damp <= 0.05 or damp > 3 or lag < -0.05 or lag > 0.1:
            return 1e9
        return sum((spring(max(0.0, t - lag), resp, damp) - y) ** 2 for t, y in zip(rel, prog)) / len(prog)

    best = None
    for r0 in (0.2, 0.35, 0.55):
        for d0 in (0.7, 0.9, 1.0):
            x, e = nelder_mead(err, [r0, d0, 0.0], [0.08, 0.15, 0.01])
            if best is None or e < best[1]:
                best = (x, e)
    (resp, damp, lag), mse = best
    overshoot = max(0.0, max(prog) - 1.0)
    t90 = next((t for t, y in zip(rel, prog) if y >= 0.9), None)
    return {
        "travel_fraction": round(abs(travel) / span, 3),
        "direction": "down" if travel > 0 else "up",
        "spring_response_s": round(resp, 3),
        "spring_damping_fraction": round(damp, 3),
        "fit_rmse": round(math.sqrt(mse), 4),
        "overshoot_pct": round(overshoot * 100, 1),
        "t90_ms": round(t90 * 1000, 1) if t90 is not None else None,
    }


def measure(clip_dir: Path, flows_path: Path) -> dict:
    meta = json.loads((clip_dir / "meta.json").read_text())
    flows = {f["id"]: f for f in json.loads(flows_path.read_text())["flows"]}
    flow = flows.get(meta["flow"])
    if flow is None:
        sys.exit(f"measure.py: unknown flow {meta['flow']!r} (flows.json)")
    w, h, pts, frames = decode(clip_dir / "clip.mp4")
    if len(frames) < 3:
        sys.exit(f"measure.py: {clip_dir} has {len(frames)} frames")
    top, bottom = region_rows(h, flow["region"])
    stim = float(meta.get("stimulus_t", 0.0))
    # the recorder's frame period: the most common short gap
    gaps = sorted(b - a for a, b in zip(pts, pts[1:]) if b > a)
    period = float(meta.get("frame_period_s") or 0) or (1.0 / float(meta["fps_nominal"]) if meta.get("fps_nominal") else (gaps[len(gaps) // 10] if gaps else 1 / 60))
    diffs = [0.0] + [frame_diff(frames[i - 1], frames[i], w, top, bottom) for i in range(1, len(frames))]
    def is_change(i: int) -> bool:
        return diffs[i] >= CHANGE or tile_diff(frames[i - 1], frames[i], w, top, bottom) >= TILE_CHANGE

    changed = [i for i in range(1, len(frames)) if pts[i] >= stim and is_change(i)]
    result: dict = {
        "app": meta.get("app"), "flow": flow["id"], "title": flow["title"], "source": meta.get("source"),
        "device": meta.get("device"), "build": meta.get("build") or meta.get("app_version"),
        "recorded_at": meta.get("recorded_at"), "frames_total": len(frames),
        "frame_period_ms": round(period * 1000, 2), "fps_nominal": round(1 / period, 1),
    }
    if not changed:
        result.update({"response_ms": None, "note": "no change after the stimulus"})
        return result
    if flow.get("response_after_stimulus_change"):
        # the first burst is the send feedback, not the answer: skip it
        k = 1
        while k < len(changed) and (pts[changed[k]] - pts[changed[k - 1]]) * 1000 <= FEEDBACK_STILL_MS:
            k += 1
        result["feedback_ms"] = round((pts[changed[0]] - stim) * 1000, 1)
        changed = changed[k:]
        if not changed:
            result.update({"response_ms": None,
                           "note": "only the send feedback changed; no answer in the clip (end the clip later)"})
            return result
    first = changed[0]
    # settle: the last change before STILL_MS of stillness (or the clip's end)
    last = first
    for i in changed[1:]:
        if (pts[i] - pts[last]) * 1000 > STILL_MS and not flow.get("streaming"):
            break
        last = i
    bursts, prev = 1, first
    for i in changed[1:]:
        if (pts[i] - pts[prev]) * 1000 > STILL_MS:
            bursts += 1
        prev = i
    moving = [i for i in changed if first <= i <= last]
    edge = flow.get("edge")
    disp, span, i0 = None, 0, max(0, first - 1)
    if edge and last > first:
        disp, span = track_edge(frames, w, h, top, bottom, i0, last, edge)
    # how far the screen moved into frame i: the edge's step when tracked, else the pixel change
    def step(i: int) -> float:
        if disp is not None and i0 < i <= last:
            return abs(disp[i - i0] - disp[i - i0 - 1])
        return diffs[i]
    dropped, worst = 0, 0.0
    for prev_i, a, b in zip([None] + moving, moving, moving[1:]):
        gap = pts[b] - pts[a]
        worst = max(worst, gap)
        k = round(gap / period)
        if k < 2 or gap * 1000 > STILL_MS:
            continue
        # A missed frame makes the next one catch up (a bigger step than the one before);
        # a slow spring tail that moves less than a pixel a frame leaves gaps without one.
        before = step(a) if disp is not None else (diffs[a] if prev_i is not None else 0)
        if step(b) >= 1.4 * before and step(b) > 0:
            dropped += k - 1
    result.update({
        "response_ms": round((pts[first] - stim) * 1000, 1),
        "settle_ms": round((pts[last] - stim) * 1000, 1),
        "motion_ms": round((pts[last] - pts[first]) * 1000, 1),
        "frames": len(moving),
        "dropped": dropped,
        "worst_gap_ms": round(worst * 1000, 1),
        "bursts": bursts,
    })
    if flow.get("streaming") and len(moving) > 2:
        upd = sorted(pts[b] - pts[a] for a, b in zip(moving, moving[1:]))
        dur = pts[moving[-1]] - pts[moving[0]]
        result["stream"] = {"updates_per_s": round((len(moving) - 1) / dur, 1) if dur > 0 else None,
                            "median_gap_ms": round(upd[len(upd) // 2] * 1000, 1)}
    if disp is not None:
        # speed per frame period into each drawn frame (a catch-up after a missed frame is not a jump)
        ts = pts[i0:last + 1]
        moves = [(abs(disp[j] - disp[j - 1]), max(1, round((ts[j] - ts[j - 1]) / period)))
                 for j in range(1, len(disp)) if disp[j] != disp[j - 1]]
        speed = [d / k for d, k in moves]
        # a jump: one frame moves more than 2% of the screen, over 3x as fast as the frames around it
        result["jumps"] = sum(
            1 for j, (d, _) in enumerate(moves)
            if d > 0.02 * span and speed[j] > 3 * max(speed[j - 1] if j else 0, speed[j + 1] if j + 1 < len(speed) else 0)
        )
        # fit on the frames the screen drew: a missed slot repeats a stale position
        drawn = [0] + [j for j in range(1, len(disp)) if (i0 + j) in set(moving)]
        curve = fit_curve([pts[i0 + j] for j in drawn], [disp[j] for j in drawn], span)
        if curve:
            result["curve"] = curve
    else:
        result["jumps"] = None
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("clip_dir", type=Path)
    ap.add_argument("--flows", type=Path, default=HERE / "flows.json")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    res = measure(args.clip_dir, args.flows)
    (args.clip_dir / "result.json").write_text(json.dumps(res, indent=2) + "\n")
    if args.json:
        print(json.dumps(res))
    else:
        for k, v in res.items():
            print(f"{k:16} {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
