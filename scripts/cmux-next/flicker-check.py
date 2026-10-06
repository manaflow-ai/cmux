#!/usr/bin/env python3
"""Finds chrome that blinks or settles in steps in a screen recording.

Record one scripted interaction (hover, open, switch) at 60 fps, then:

  scripts/cmux-next/flicker-check.py RECORDING.mp4 [--crop x,y,w,h] [--frames-dir DIR]

The recording is scaled down to a grid of cells and each cell's mean
brightness is followed frame by frame. Two patterns are reported:

- blink: a cell changes and returns to its earlier value within
  --blink-frames (default 6, 100 ms at 60 fps). Something mounted and
  unmounted, or faded out and back in. A caret blinks slower than this.
- staggered: one burst of change in the area (gaps no longer than
  --settle-frames, default 18 = 300 ms) lands in --steps or more separate
  steps (default 3; consecutive moving frames, a fade, are one step).
  Content arrived in pieces, or a control popped in and then moved,
  instead of drawing once at its final size.

Exits 1 when anything is found, so a scripted capture can gate on it.
--frames-dir writes the frames around each finding as PNGs for review.
Pure Python plus ffmpeg; no numpy.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

WIDTH = 192


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,avg_frame_rate", "-of", "json", str(path)],
        check=True, capture_output=True, text=True).stdout
    stream = json.loads(out)["streams"][0]
    num, den = stream["avg_frame_rate"].split("/")
    return stream["width"], stream["height"], float(num) / float(den or 1)


def frames(path, crop, width, height):
    filters = []
    if crop:
        filters.append("crop={2}:{3}:{0}:{1}".format(*crop))
    filters.append(f"scale={width}:{height}:flags=area,format=gray")
    proc = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", str(path), "-vf", ",".join(filters), "-f", "rawvideo", "-"],
        stdout=subprocess.PIPE)
    size = width * height
    while True:
        chunk = proc.stdout.read(size)
        if len(chunk) < size:
            break
        yield chunk
    proc.wait()


def cell_means(frame, width, height, cell):
    means = []
    for top in range(0, height - cell + 1, cell):
        for left in range(0, width - cell + 1, cell):
            total = 0
            for row in range(top, top + cell):
                start = row * width + left
                total += sum(frame[start:start + cell])
            means.append(total / (cell * cell))
    return means


def find(series, change, blink_frames):
    """series[i][c] is cell c's mean in frame i."""
    findings = []
    cells = len(series[0]) if series else 0
    for c in range(cells):
        values = [frame[c] for frame in series]
        moves = [i for i in range(1, len(values)) if abs(values[i] - values[i - 1]) > change]
        reported = -1
        for i in moves:
            if i <= reported:
                continue
            before = values[i - 1]
            for j in range(i + 1, min(len(values), i + blink_frames + 1)):
                if abs(values[j] - before) <= change / 2 and all(
                        abs(values[k] - before) <= change / 2 for k in range(j, min(len(values), j + 3))):
                    findings.append({"kind": "blink", "cell": c, "frame": i, "frames": j - i})
                    reported = j
                    break
    return findings


def staggered(series, change, settle_frames, steps, columns, cell):
    """One interaction's changes, anywhere in the area, that land in separate
    steps (not one continuous fade) within settle_frames."""
    moving = []
    for i in range(1, len(series)):
        cells = [c for c, (a, b) in enumerate(zip(series[i - 1], series[i])) if abs(b - a) > change]
        if cells:
            moving.append((i, cells))
    events, index = [], 0
    while index < len(moving):
        burst = [moving[index]]
        while index + len(burst) < len(moving) and moving[index + len(burst)][0] - burst[-1][0] <= settle_frames:
            burst.append(moving[index + len(burst)])
        index += len(burst)
        frames = [f for f, _ in burst]
        distinct = [f for n, f in enumerate(frames) if n == 0 or f - frames[n - 1] > 1]
        if len(distinct) >= steps:
            touched = {c for _, cells in burst for c in cells}
            xs = [(c % columns) * cell for c in touched]
            ys = [(c // columns) * cell for c in touched]
            events.append({"kind": "staggered", "frame": frames[0], "frames": frames[-1] - frames[0],
                           "steps": len(distinct), "step_frames": distinct, "cells": len(touched),
                           "box": [min(xs), min(ys), max(xs) + cell, max(ys) + cell]})
    return events


def merge(findings, columns, cell, scale, fps):
    """Groups cells that report the same kind at nearly the same frame."""
    events = []
    for f in sorted(findings, key=lambda f: (f["kind"], f["frame"])):
        x, y = (f["cell"] % columns) * cell, (f["cell"] // columns) * cell
        last = events[-1] if events else None
        if last and last["kind"] == f["kind"] and abs(last["frame"] - f["frame"]) <= 2:
            last["cells"] += 1
            last["box"] = [min(last["box"][0], x), min(last["box"][1], y),
                           max(last["box"][2], x + cell), max(last["box"][3], y + cell)]
            continue
        events.append({"kind": f["kind"], "frame": f["frame"], "ms": round(f["frame"] * 1000 / fps),
                       "duration_ms": round(f["frames"] * 1000 / fps), "cells": 1,
                       "box": [x, y, x + cell, y + cell]})
    for event in events:
        # Back to source pixels (of the cropped area).
        event["box"] = [round(v * scale) for v in event["box"]]
    return events


def dump(path, crop, events, directory, fps):
    directory.mkdir(parents=True, exist_ok=True)
    for n, event in enumerate(events):
        first = max(0, event["frame"] - 1)
        count = round(event["duration_ms"] * fps / 1000) + 3
        filters = ["crop={2}:{3}:{0}:{1}".format(*crop)] if crop else []
        filters.append(f"select='between(n\\,{first}\\,{first + count - 1})'")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(path), "-vf", ",".join(filters),
                        "-vsync", "0", str(directory / f"{n:02d}-{event['kind']}-f%04d.png")], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("recording", type=Path)
    parser.add_argument("--crop", help="x,y,w,h in source pixels: the window or the control under test")
    parser.add_argument("--cell", type=int, default=6, help="grid cell size after scaling to 192 px wide")
    parser.add_argument("--change", type=float, default=6.0, help="mean brightness step (0-255) that counts")
    parser.add_argument("--blink-frames", type=int, default=6)
    parser.add_argument("--settle-frames", type=int, default=18)
    parser.add_argument("--steps", type=int, default=3)
    parser.add_argument("--min-cells", type=int, default=1, help="ignore events touching fewer cells")
    parser.add_argument("--frames-dir", type=Path)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    width, height, fps = probe(args.recording)
    crop = [int(v) for v in args.crop.split(",")] if args.crop else None
    source_width, source_height = (crop[2], crop[3]) if crop else (width, height)
    scaled_height = max(args.cell, round(source_height * WIDTH / source_width))
    series = [cell_means(f, WIDTH, scaled_height, args.cell) for f in frames(args.recording, crop, WIDTH, scaled_height)]
    if fps < 50:
        print(f"warning: {fps:.1f} fps; a one-frame blink at 60 Hz can fall between frames", file=sys.stderr)

    columns = WIDTH // args.cell
    scale = source_width / WIDTH
    events = merge(find(series, args.change, args.blink_frames), columns, args.cell, scale, fps)
    for event in staggered(series, args.change, args.settle_frames, args.steps, columns, args.cell):
        event["ms"], event["duration_ms"] = round(event["frame"] * 1000 / fps), round(event["frames"] * 1000 / fps)
        event["box"] = [round(v * scale) for v in event["box"]]
        del event["frames"]
        events.append(event)
    events = [e for e in events if e["cells"] >= args.min_cells]
    result = {"recording": str(args.recording), "fps": round(fps, 2), "frames": len(series), "events": events}
    for e in events:
        print(f"{e['kind']:<9} t={e['ms']}ms frame={e['frame']} lasts={e['duration_ms']}ms "
              f"cells={e['cells']} box={e['box']}" + (f" steps={e.get('steps')}" if e.get("steps") else ""))
    print(f"{len(events)} events in {len(series)} frames at {fps:.1f} fps")
    if args.json:
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    if args.frames_dir and events:
        dump(args.recording, crop, events, args.frames_dir, fps)
    sys.exit(1 if events else 0)


if __name__ == "__main__":
    main()
