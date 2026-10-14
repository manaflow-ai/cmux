#!/usr/bin/env python3
"""framediff.py - compare an animation in a reference capture against an implementation.

Inputs are two videos (anything ffmpeg can read) or two directories of PNG frames
(sorted by name). Both sequences are aligned on motion onset, then per-frame
metrics of the moving region are reported:

  * bbox (x, y, w, h) of pixels that differ from the pre-onset frame, in points
  * centroid of the moving region and its displacement from onset
  * progress p in [0, 1] (how far the frame is between the start and end state)
  * optional template tracking (--track): x, y, scale, and opacity proxy of a
    specific element (e.g. a bubble or a nav-bar title) found by multi-scale
    normalized cross-correlation
  * ref-vs-impl deltas per aligned frame plus a summary (duration, frame counts,
    max/mean position and scale error)

and a contact sheet PNG (ref | impl | |diff| per row) is written.

Usage
-----
  python3 -I framediff.py REF IMPL [options]

  REF / IMPL       video file or directory of frames
  --fps 60         frame rate used when extracting videos (default 60)
  --scale 3        pixels per point of the inputs (default 3 = iPhone @3x)
  --crop x,y,w,h   only analyse this region, in POINTS (applied to both)
  --track x,y,w,h  template region in POINTS, taken from the REF onset frame;
                   include a few points of background around the element so
                   the match is unambiguous (solid fills alone are not)
                   (or from --track-frame). The same template is searched in
                   both sequences, so the element must look alike in both.
  --track-frame N  REF frame index (relative to onset, may be negative) for
                   the template (default -1 = last pre-onset frame)
  --track-impl x,y,w,h  separate template region for IMPL (default: reuse REF template)
  --threshold 12   per-pixel |diff| (0-255 gray) to count as changed
  --onset-frac 0.0005  fraction of changed pixels that marks motion onset
  --settle-frac F  frame-to-frame changed fraction still counted as motion
                   when finding the end of the animation (default onset-frac/5)
  --pre 3          frames kept before onset
  --max-frames 90  frames analysed after onset
  --sheet-every 2  contact sheet row stride (aligned frames)
  --out DIR        output directory (default ./framediff-out)
  --json           also print the JSON summary to stdout

The summary includes a SwiftUI-style spring fit (response, dampingFraction) of
each progress curve, so `Animation.spring(response:dampingFraction:)` values can
be compared directly. A single sequence can be analysed by passing the same
input twice.

Outputs (in --out): report.txt, report.json, contact_sheet.png.

Simulator recordings (simctl io recordVideo) are variable-frame-rate and drop
frames under load; videos are resampled to --fps on a fixed grid, so a dropped
stretch shows up as repeated frames. Compare durations, not single frames, and
prefer `--track` on a distinctive element for position curves.

Requires numpy + Pillow (e.g. ~/nxios-ref/venv/bin/python -I framediff.py ...)
and ffmpeg on PATH for video inputs.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

try:
    import numpy as np
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    sys.exit("framediff.py needs numpy and Pillow (try ~/nxios-ref/venv/bin/python -I framediff.py)")


# ---------------------------------------------------------------- loading

def extract_frames(src: str, fps: float, tmp: str) -> list[str]:
    if os.path.isdir(src):
        names = sorted(n for n in os.listdir(src) if n.lower().endswith((".png", ".jpg", ".jpeg")))
        return [os.path.join(src, n) for n in names]
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg not found; pass frame directories instead")
    out = os.path.join(tmp, os.path.basename(src) + ".frames")
    os.makedirs(out, exist_ok=True)
    # fps filter resamples variable-frame-rate simulator recordings onto a fixed grid
    subprocess.run(["ffmpeg", "-v", "error", "-i", src, "-vf", f"fps={fps}", os.path.join(out, "f%05d.png")],
                   check=True)
    return [os.path.join(out, n) for n in sorted(os.listdir(out))]


def load_gray(path: str, crop_px):
    im = Image.open(path).convert("RGB")
    if crop_px:
        x, y, w, h = crop_px
        im = im.crop((x, y, x + w, y + h))
    return im, np.asarray(im.convert("L"), dtype=np.float32)


# ---------------------------------------------------------------- analysis

def find_onset(grays, threshold, frac):
    base = grays[0]
    n = base.size
    for i in range(1, len(grays)):
        if (np.abs(grays[i] - base) > threshold).sum() / n > frac:
            return i
    return None


def find_settle(grays, onset, threshold, frac):
    """Last frame (index) where the frame still differs from the next one."""
    n = grays[0].size
    last = onset
    for i in range(onset, len(grays) - 1):
        if (np.abs(grays[i + 1] - grays[i]) > threshold).sum() / n > frac:
            last = i + 1
    return last


def region_metrics(g, base, end, threshold, scale):
    d = np.abs(g - base) > threshold
    ys, xs = np.nonzero(d)
    if len(xs) == 0:
        bbox = None
        cen = None
    else:
        bbox = [xs.min() / scale, ys.min() / scale, (xs.max() - xs.min() + 1) / scale,
                (ys.max() - ys.min() + 1) / scale]
        cen = [xs.mean() / scale, ys.mean() / scale]
    # progress: projection of (g - base) onto (end - base)
    v = (end - base).ravel().astype(np.float64)
    vv = float(np.dot(v, v))
    p = float(np.dot((g - base).ravel().astype(np.float64), v) / vv) if vv > 0 else 0.0
    return bbox, cen, p


def _ncc_map(img, tpl):
    """Normalized cross-correlation of tpl over img (valid positions) via FFT."""
    img = img.astype(np.float64)
    tpl = tpl.astype(np.float64)
    H, W = img.shape
    h, w = tpl.shape
    if h > H or w > W:
        return None
    t = tpl - tpl.mean()
    tn = np.sqrt((t * t).sum()) or 1.0
    fs = (H + h, W + w)
    F = np.fft.rfft2(img, fs)
    T = np.fft.rfft2(t[::-1, ::-1], fs)
    corr = np.fft.irfft2(F * T, fs)[h - 1:H, w - 1:W]
    # local sums for normalization
    ii = np.pad(img, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    ii2 = np.pad(img * img, ((1, 0), (1, 0))).cumsum(0).cumsum(1)

    def box(a):
        return a[h:, w:] - a[:-h, w:] - a[h:, :-w] + a[:-h, :-w]

    s = box(ii)
    s2 = box(ii2)
    var = s2 - s * s / (h * w)
    # flat windows have ~0 variance; FFT noise would explode there, so score them 0
    flat = var < max(1e-3, 1e-3 * tn * tn)
    out = corr / (np.sqrt(np.where(flat, 1.0, var)) * tn)
    out[flat] = 0.0
    return out


def track(g, tpl, ds, scales, prev=None):
    """Multi-scale template search on a downsampled image. Returns x,y,w,h (px), scale, score."""
    small = np.asarray(Image.fromarray(g).resize((max(1, g.shape[1] // ds), max(1, g.shape[0] // ds)),
                                                  Image.BILINEAR), dtype=np.float32)
    best = None
    for s in scales:
        th = max(4, int(round(tpl.shape[0] * s / ds)))
        tw = max(4, int(round(tpl.shape[1] * s / ds)))
        t = np.asarray(Image.fromarray(tpl).resize((tw, th), Image.BILINEAR), dtype=np.float32)
        m = _ncc_map(small, t)
        if m is None:
            continue
        idx = np.unravel_index(np.argmax(m), m.shape)
        sc = float(m[idx])
        rank = sc - 0.02 * abs(np.log(s))  # prefer scale 1 on near-ties
        if best is None or rank > best[-1]:
            best = (idx[1] * ds, idx[0] * ds, tw * ds, th * ds, s, sc, rank)
    if best and ds > 1:
        # refine at full resolution in a small window around the coarse hit
        bx, by, _, _, s, _, _ = best
        th = max(4, int(round(tpl.shape[0] * s)))
        tw = max(4, int(round(tpl.shape[1] * s)))
        t = np.asarray(Image.fromarray(tpl).resize((tw, th), Image.BILINEAR), dtype=np.float32)
        r = 2 * ds
        x0, y0 = max(0, bx - r), max(0, by - r)
        win = g[y0:by + th + r, x0:bx + tw + r]
        m = _ncc_map(win, t)
        if m is not None and m.size:
            idx = np.unravel_index(np.argmax(m), m.shape)
            best = (x0 + idx[1], y0 + idx[0], tw, th, s, float(m[idx]), 0)
    if best:
        best = best[:6]
    return best


def opacity_proxy(g, box, ref_box_mean, bg):
    x, y, w, h = [int(v) for v in box]
    patch = g[max(0, y):y + h, max(0, x):x + w]
    if patch.size == 0 or abs(ref_box_mean - bg) < 1:
        return None
    return float(np.clip((patch.mean() - bg) / (ref_box_mean - bg), 0, 2))


def analyse(paths, args, label, tpl_box_pt=None, tpl_override=None):
    crop_px = [int(v * args.scale) for v in args.crop] if args.crop else None
    rgbs, grays = [], []
    for p in paths:
        im, g = load_gray(p, crop_px)
        rgbs.append(im)
        grays.append(g)
    if not grays:
        sys.exit(f"{label}: no frames")
    onset = find_onset(grays, args.threshold, args.onset_frac)
    if onset is None:
        sys.exit(f"{label}: no motion detected (lower --threshold/--onset-frac?)")
    settle = find_settle(grays, onset, args.threshold, args.settle_frac if args.settle_frac is not None else args.onset_frac / 5)
    start = max(0, onset - args.pre)
    stop = min(len(grays), onset + args.max_frames)
    base = grays[onset - 1]
    end = grays[settle]
    rows = []
    tpl = tpl_override
    tpl_mean = bg = None
    if tpl is None and tpl_box_pt:
        fi = onset - 1 if args.track_frame == -1 else onset + args.track_frame
        x, y, w, h = [int(v * args.scale) for v in tpl_box_pt]
        if crop_px:
            x -= crop_px[0]
            y -= crop_px[1]
        tpl = grays[fi][y:y + h, x:x + w].copy()
    if tpl is not None:
        tpl_mean = float(tpl.mean())
        bg = float(np.median(np.concatenate([base[0], base[-1], base[:, 0], base[:, -1]])))
    scales = [round(0.5 + 0.05 * i, 2) for i in range(21)]  # 0.5 .. 1.5
    for i in range(start, stop):
        bbox, cen, p = region_metrics(grays[i], base, end, args.threshold, args.scale)
        r = {"frame": i - onset, "t_ms": round((i - onset) * 1000 / args.fps, 1), "bbox": bbox,
             "centroid": cen, "progress": round(p, 4)}
        if tpl is not None:
            tr = track(grays[i], tpl, args.ds, scales)
            if tr:
                tx, ty, tw, th, s, sc = tr
                r["track"] = {"x": tx / args.scale, "y": ty / args.scale, "w": tw / args.scale,
                              "h": th / args.scale, "scale": s, "score": round(sc, 3),
                              "opacity": opacity_proxy(grays[i], (tx, ty, tw, th), tpl_mean, bg)}
        rows.append(r)
    return {"label": label, "onset": onset, "settle": settle, "frames": len(grays),
            "duration_frames": settle - onset + 1, "duration_ms": round((settle - onset + 1) * 1000 / args.fps, 1),
            "rows": rows, "rgb": rgbs[start:stop], "gray": grays[start:stop], "tpl": tpl}


# ---------------------------------------------------------------- reporting

def spring_curve(t, response, damping):
    """SwiftUI-style spring (response = 2*pi/omega0, damping fraction) step response 0 -> 1."""
    w0 = 2 * np.pi / response
    z = damping
    if z < 1:
        wd = w0 * np.sqrt(1 - z * z)
        return 1 - np.exp(-z * w0 * t) * (np.cos(wd * t) + z * w0 / wd * np.sin(wd * t))
    return 1 - np.exp(-w0 * t) * (1 + w0 * t)


def fit_spring(rows):
    """Grid-fit response/damping (and a sub-frame onset shift) to the progress curve."""
    rows = [r for r in rows if r["frame"] >= -1]
    ts = np.array([r["t_ms"] / 1000 for r in rows])
    src = "progress"
    ps = np.array([r["progress"] for r in rows])
    if rows and all("track" in r for r in rows):
        # tracked element: use its normalized displacement + scale change instead
        x0, y0, s0 = rows[0]["track"]["x"], rows[0]["track"]["y"], rows[0]["track"]["scale"]
        xe, ye, se = rows[-1]["track"]["x"], rows[-1]["track"]["y"], rows[-1]["track"]["scale"]
        dx, dy, ds_ = xe - x0, ye - y0, se - s0
        den = dx * dx + dy * dy + (100 * ds_) ** 2
        if den > 1:
            ps = np.array([((r["track"]["x"] - x0) * dx + (r["track"]["y"] - y0) * dy
                            + 1e4 * (r["track"]["scale"] - s0) * ds_) / den for r in rows])
            src = "track"

    if len(ts) < 4:
        return None
    best = None
    for resp in np.arange(0.10, 1.01, 0.01):
        for damp in np.arange(0.50, 1.001, 0.02):
            for shift in np.arange(-0.016, 0.0161, 0.004):
                tt = np.clip(ts - shift, 0, None)
                e = float(np.mean((spring_curve(tt, resp, damp) - ps) ** 2))
                if best is None or e < best[0]:
                    best = (e, resp, damp, shift)
    e, resp, damp, shift = best
    return {"response_s": round(float(resp), 3), "damping": round(float(damp), 3),
            "onset_shift_ms": round(shift * 1000, 1), "rmse": round(e ** 0.5, 4), "source": src}


def fmt(v, nd=1):
    return "-" if v is None else f"{v:.{nd}f}"


def compare(ref, imp):
    n = min(len(ref["rows"]), len(imp["rows"]))
    out = []
    pos_err, scale_err, prog_err, op_err = [], [], [], []
    for k in range(n):
        a, b = ref["rows"][k], imp["rows"][k]
        d = {"frame": a["frame"], "dprogress": round(b["progress"] - a["progress"], 4)}
        prog_err.append(abs(d["dprogress"]))
        if a["centroid"] and b["centroid"]:
            d["dcentroid"] = [round(b["centroid"][0] - a["centroid"][0], 2), round(b["centroid"][1] - a["centroid"][1], 2)]
        if "track" in a and "track" in b:
            ta, tb = a["track"], b["track"]
            d["dx"] = round(tb["x"] - ta["x"], 2)
            d["dy"] = round(tb["y"] - ta["y"], 2)
            d["dscale"] = round(tb["scale"] - ta["scale"], 3)
            pos_err.append((d["dx"] ** 2 + d["dy"] ** 2) ** 0.5)
            scale_err.append(abs(d["dscale"]))
            if ta["opacity"] is not None and tb["opacity"] is not None:
                d["dopacity"] = round(tb["opacity"] - ta["opacity"], 3)
                op_err.append(abs(d["dopacity"]))
        out.append(d)

    summary_fit = {"ref_spring": fit_spring(ref["rows"]), "impl_spring": fit_spring(imp["rows"])}

    def stats(xs):
        return {"max": round(max(xs), 3), "mean": round(sum(xs) / len(xs), 3)} if xs else None

    summary = {"ref_duration_frames": ref["duration_frames"], "impl_duration_frames": imp["duration_frames"],
               "ref_duration_ms": ref["duration_ms"], "impl_duration_ms": imp["duration_ms"],
               "duration_delta_frames": imp["duration_frames"] - ref["duration_frames"],
               "progress_err": stats(prog_err), "track_pos_err_pt": stats(pos_err),
               "track_scale_err": stats(scale_err), "track_opacity_err": stats(op_err)}
    summary.update(summary_fit)
    return out, summary


def contact_sheet(ref, imp, every, path, thumb_w=220):
    n = min(len(ref["rgb"]), len(imp["rgb"]))
    idxs = list(range(0, n, max(1, every)))
    if not idxs:
        return
    r0 = ref["rgb"][0]
    tw = thumb_w
    th = int(r0.height * tw / r0.width)
    pad, lab = 6, 16
    W = 3 * tw + 4 * pad
    H = len(idxs) * (th + lab + pad) + pad
    sheet = Image.new("RGB", (W, H), (40, 40, 40))
    dr = ImageDraw.Draw(sheet)
    y = pad
    for k in idxs:
        a = ref["rgb"][k].resize((tw, th))
        b = imp["rgb"][k].resize((tw, th))
        da = np.asarray(a, dtype=np.int16)
        db = np.asarray(b, dtype=np.int16)
        diff = np.clip(np.abs(da - db).sum(2) * 2, 0, 255).astype(np.uint8)
        dimg = Image.fromarray(diff).convert("RGB")
        f = ref["rows"][k]["frame"]
        dr.text((pad, y), f"frame {f:+d} ({f * 1000 / 60:.0f} ms)  ref | impl | diff", fill=(230, 230, 230))
        y += lab
        for c, im in enumerate((a, b, dimg)):
            sheet.paste(im, (pad + c * (tw + pad), y))
        y += th + pad
    sheet.save(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ref")
    ap.add_argument("impl")
    ap.add_argument("--fps", type=float, default=60)
    ap.add_argument("--scale", type=float, default=3)
    ap.add_argument("--crop", type=lambda s: [float(v) for v in s.split(",")])
    ap.add_argument("--track", type=lambda s: [float(v) for v in s.split(",")])
    ap.add_argument("--track-impl", type=lambda s: [float(v) for v in s.split(",")])
    ap.add_argument("--track-frame", type=int, default=-1)
    ap.add_argument("--threshold", type=float, default=12)
    ap.add_argument("--onset-frac", type=float, default=0.0005)
    ap.add_argument("--settle-frac", type=float, default=None,
                    help="changed-pixel fraction between consecutive frames that still counts as motion (default onset-frac/5)")
    ap.add_argument("--pre", type=int, default=3)
    ap.add_argument("--max-frames", type=int, default=90)
    ap.add_argument("--sheet-every", type=int, default=2)
    ap.add_argument("--ds", type=int, default=3, help="downsample factor for template search")
    ap.add_argument("--out", default="framediff-out")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        rp = extract_frames(args.ref, args.fps, tmp)
        ip = extract_frames(args.impl, args.fps, tmp)
        ref = analyse(rp, args, "ref", args.track)
        if args.track_impl:
            imp = analyse(ip, args, "impl", args.track_impl)
        else:
            imp = analyse(ip, args, "impl", None, ref["tpl"])
    rows, summary = compare(ref, imp)
    lines = [f"ref : onset frame {ref['onset']}, settle {ref['settle']}, duration {ref['duration_frames']} frames ({ref['duration_ms']} ms)",
             f"impl: onset frame {imp['onset']}, settle {imp['settle']}, duration {imp['duration_frames']} frames ({imp['duration_ms']} ms)",
             "",
             "frame  t_ms | ref prog  impl prog | ref centroid      impl centroid     | track ref x,y,s,op        impl x,y,s,op             | dx    dy    ds     dop"]
    for k, d in enumerate(rows):
        a, b = ref["rows"][k], imp["rows"][k]
        ca = a["centroid"] or [None, None]
        cb = b["centroid"] or [None, None]
        ta = a.get("track") or {}
        tb = b.get("track") or {}

        def tstr(t):
            if not t:
                return "-".ljust(25)
            return f"{t['x']:6.1f},{t['y']:6.1f},{t['scale']:.2f},{fmt(t['opacity'], 2)}".ljust(25)

        lines.append(f"{d['frame']:+5d} {a['t_ms']:6.1f} | {a['progress']:7.3f}  {b['progress']:8.3f} | "
                     f"{fmt(ca[0])},{fmt(ca[1])}".ljust(0) + "  " + f"{fmt(cb[0])},{fmt(cb[1])}".ljust(18)
                     + " | " + tstr(ta) + " " + tstr(tb) + " | "
                     + f"{fmt(d.get('dx'))} {fmt(d.get('dy'))} {fmt(d.get('dscale'), 3)} {fmt(d.get('dopacity'), 3)}")
    lines += ["", "summary: " + json.dumps(summary)]
    txt = "\n".join(lines)
    print(txt)
    with open(os.path.join(args.out, "report.txt"), "w") as f:
        f.write(txt + "\n")
    payload = {"summary": summary, "deltas": rows,
               "ref": {k: v for k, v in ref.items() if k not in ("rgb", "gray", "tpl")},
               "impl": {k: v for k, v in imp.items() if k not in ("rgb", "gray", "tpl")}}
    with open(os.path.join(args.out, "report.json"), "w") as f:
        json.dump(payload, f, indent=1)
    contact_sheet(ref, imp, args.sheet_every, os.path.join(args.out, "contact_sheet.png"))
    if args.json:
        print(json.dumps(payload["summary"], indent=1))
    print(f"\nwrote {args.out}/report.txt, report.json, contact_sheet.png")


if __name__ == "__main__":
    main()
