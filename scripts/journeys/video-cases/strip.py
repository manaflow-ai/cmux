#!/usr/bin/env python3
"""Frame strips of one recorded motion, for judging every frame by eye (RESIZE VIDEOS suite).

  strip.py MOVIE.mov --out DIR [--from F] [--to T] [--crop x,y,w,h] [--scale 0.5] [--cols 6] [--ffmpeg PATH]

Decodes every frame of MOVIE (HEVC or ProRes, as `debug.motion` record_* writes it) in [F, T] (movie frame
indexes; default all), and writes DIR/frame-NNNNN.png (the crop, full resolution), DIR/sheet-NN.png (contact
sheets, COLS x 4 frames each, every frame labelled with its index and its time from the first frame) and
DIR/diff-NN.png (the same sheets of |frame - frame before|, brightened: what changed in each refresh; a frame
with no change while the layout moves is a repeated frame). Needs numpy and Pillow (the VM venv
/work/tmp/resize-suite/venv) and an ffmpeg with an HEVC decoder (imageio-ffmpeg's static build).
"""
import argparse
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw


def ffmpeg_path(given):
    if given:
        return given
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        return "ffmpeg"


def probe_size(ff, movie):
    out = subprocess.run([ff, "-hide_banner", "-i", movie], capture_output=True, text=True).stderr
    for line in out.splitlines():
        if "Video:" in line:
            for part in line.split(","):
                part = part.strip().split(" ")[0]
                if "x" in part and part.replace("x", "").isdigit():
                    w, h = part.split("x")
                    return int(w), int(h)
    sys.exit(f"no video size in {movie}: {out[-400:]}")


def frames(ff, movie, first, last):
    w, h = probe_size(ff, movie)
    sel = f"select='between(n\\,{first}\\,{last})'" if last is not None else f"select='gte(n\\,{first})'"
    cmd = [ff, "-hide_banner", "-loglevel", "error", "-i", movie, "-vf", sel, "-vsync", "0",
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    size = w * h * 3
    n = first
    while True:
        buf = proc.stdout.read(size)
        if len(buf) < size:
            break
        yield n, np.frombuffer(buf, np.uint8).reshape(h, w, 3)
        n += 1
    proc.wait()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("movie")
    ap.add_argument("--out", required=True)
    ap.add_argument("--from", dest="first", type=int, default=0)
    ap.add_argument("--to", dest="last", type=int)
    ap.add_argument("--crop")
    ap.add_argument("--scale", type=float, default=0.5, help="sheet tile scale (frames keep full size)")
    ap.add_argument("--cols", type=int, default=6)
    ap.add_argument("--ffmpeg")
    ap.add_argument("--times", help="MOVIE.frames.json: label each frame with its display time")
    opts = ap.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    ff = ffmpeg_path(opts.ffmpeg)
    times = None
    if opts.times:
        with open(opts.times) as f:
            rows = json.load(f)
        rows = rows.get("frames", rows) if isinstance(rows, dict) else rows
        times = [float(r[0]) for r in rows if isinstance(r, list) and len(r) > 2 and r[2]]
    crop = [int(v) for v in opts.crop.split(",")] if opts.crop else None
    tiles, diffs, prev, sheet_n, t0 = [], [], None, 0, None
    per_sheet = opts.cols * 4

    def flush():
        nonlocal tiles, diffs, sheet_n
        if not tiles:
            return
        for name, group in (("sheet", tiles), ("diff", diffs)):
            tw, th = group[0].size
            sheet = Image.new("RGB", (tw * opts.cols, th * ((len(group) + opts.cols - 1) // opts.cols)), (40, 40, 40))
            for k, tile in enumerate(group):
                sheet.paste(tile, ((k % opts.cols) * tw, (k // opts.cols) * th))
            sheet.save(os.path.join(opts.out, f"{name}-{sheet_n:02d}.png"))
        sheet_n += 1
        tiles, diffs = [], []

    for n, frame in frames(ff, opts.movie, opts.first, opts.last):
        if crop:
            x, y, w, h = crop
            frame = frame[y:y + h, x:x + w]
        Image.fromarray(frame).save(os.path.join(opts.out, f"frame-{n:05d}.png"))
        t = times[n] if times and n < len(times) else None
        if t is not None and t0 is None:
            t0 = t
        label = f"#{n}" + (f" {1000 * (t - t0):.1f}ms" if t is not None else "")
        size = (max(1, int(frame.shape[1] * opts.scale)), max(1, int(frame.shape[0] * opts.scale)))
        tile = Image.fromarray(frame).resize(size, Image.BILINEAR)
        ImageDraw.Draw(tile).text((4, 4), label, fill=(255, 0, 255))
        tiles.append(tile)
        if prev is None:
            d = np.zeros_like(frame)
        else:
            d = np.clip(np.abs(frame.astype(np.int16) - prev.astype(np.int16)) * 4, 0, 255).astype(np.uint8)
        changed = int((np.abs(frame.astype(np.int16) - (prev if prev is not None else frame).astype(np.int16)).max(axis=2) > 8).sum())
        dt = Image.fromarray(d).resize(size, Image.NEAREST)
        ImageDraw.Draw(dt).text((4, 4), f"{label} changed px {changed}", fill=(0, 255, 0))
        diffs.append(dt)
        prev = frame
        if len(tiles) == per_sheet:
            flush()
    flush()
    print(f"sheets in {opts.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
