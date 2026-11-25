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

- jump: a block of the screen is drawn again moved by a few pixels or more, up,
  down or sideways, in one frame, and then stays put. A row pushed down by a
  banner, a card that resizes and moves its neighbours, a placeholder
  replaced by content of another height: a layout shift.
- glide: the same move spread over --glide-frames or more frames (an
  animation or a scroll). Reported, never a failure.

Exits 1 when a blink, staggered or jump is found, so a scripted capture can
gate on it (--report-only always exits 0; the JSON still lists them).
--frames-dir writes the frames around each finding as PNGs for review.
A .y4m recording (YUV4MPEG2, what `ffmpeg -f yuv4mpegpipe` writes) is read
without ffmpeg, at its own frame rate; anything else is decoded by ffmpeg at
60 fps. Pure Python; no numpy.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

# Frames are analysed this many pixels wide. The blink and staggered grid
# keeps its old meaning (a --cell of 6 is 6 px at 192 wide, so 12 px here);
# a jump is measured at this width, so a move of one analysed pixel is about
# 5 px of a 1920-wide recording.
WIDTH = 384
GRID = 2
RATE = 60


def probe(path):
    if path.suffix == ".y4m":
        header = y4m_header(path)
        return header["width"], header["height"], header["fps"]
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,avg_frame_rate", "-of", "json", str(path)],
        check=True, capture_output=True, text=True).stdout
    stream = json.loads(out)["streams"][0]
    num, den = stream["avg_frame_rate"].split("/")
    return stream["width"], stream["height"], float(num) / float(den or 1)


def y4m_header(path):
    with open(path, "rb") as handle:
        line = handle.readline()
    if not line.startswith(b"YUV4MPEG2"):
        raise SystemExit(f"{path}: not a YUV4MPEG2 file")
    header = {"width": 0, "height": 0, "fps": float(RATE), "chroma": "420", "length": len(line)}
    for token in line.split()[1:]:
        tag, value = chr(token[0]), token[1:].decode()
        if tag == "W":
            header["width"] = int(value)
        elif tag == "H":
            header["height"] = int(value)
        elif tag == "F":
            num, den = value.split(":")
            header["fps"] = float(num) / float(den or 1)
        elif tag == "C":
            header["chroma"] = value
    return header


def y4m_frames(path, header):
    """Each frame's luma plane, as bytes, width * height."""
    width, height, chroma = header["width"], header["height"], header["chroma"]
    luma = width * height
    if chroma.startswith("mono"):
        extra = 0
    elif chroma.startswith("444"):
        extra = 2 * luma
    elif chroma.startswith("422"):
        extra = 2 * ((width + 1) // 2) * height
    else:
        extra = 2 * ((width + 1) // 2) * ((height + 1) // 2)
    with open(path, "rb") as handle:
        handle.seek(header["length"])
        while True:
            marker = handle.readline()
            if not marker.startswith(b"FRAME"):
                return
            plane = handle.read(luma)
            if len(plane) < luma:
                return
            handle.seek(extra, 1)
            yield plane


def scale_plane(plane, source_width, crop, width, height):
    """Box-average a luma plane (cropped to x,y,w,h) to width x height."""
    x0, y0, cw, ch = crop
    if (cw, ch) == (width, height):
        return b"".join(plane[(y0 + row) * source_width + x0:(y0 + row) * source_width + x0 + cw]
                        for row in range(ch))
    xs = [(x0 + (i * cw) // width, x0 + max((i * cw) // width + 1, ((i + 1) * cw) // width)) for i in range(width)]
    out = bytearray(width * height)
    for j in range(height):
        top, bottom = y0 + (j * ch) // height, y0 + max((j * ch) // height + 1, ((j + 1) * ch) // height)
        sums = [0] * width
        for row in range(top, bottom):
            line = plane[row * source_width:(row + 1) * source_width]
            for i, (a, b) in enumerate(xs):
                sums[i] += sum(line[a:b])
        rows = bottom - top
        for i, (a, b) in enumerate(xs):
            out[j * width + i] = sums[i] // ((b - a) * rows)
    return bytes(out)


def frames(path, crop, width, height, rate):
    if path.suffix == ".y4m":
        header = y4m_header(path)
        area = crop or [0, 0, header["width"], header["height"]]
        for plane in y4m_frames(path, header):
            yield scale_plane(plane, header["width"], area, width, height)
        return
    # A constant rate: screen recordings are variable-rate, and frame n is
    # then at n / rate (a held frame repeats).
    filters = [f"fps={rate}"]
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


def changed_regions(before, after, change, columns, rows):
    """The changed cells between two frames, as 8-connected groups: (cells, box in cells)."""
    changed = {c for c, (a, b) in enumerate(zip(before, after)) if abs(b - a) > change}
    regions = []
    while changed:
        stack = [changed.pop()]
        group = []
        while stack:
            c = stack.pop()
            group.append(c)
            cx, cy = c % columns, c // columns
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    x, y = cx + dx, cy + dy
                    n = y * columns + x
                    if 0 <= x < columns and 0 <= y < rows and n in changed:
                        changed.remove(n)
                        stack.append(n)
        xs = [c % columns for c in group]
        ys = [c // columns for c in group]
        regions.append((len(group), [min(xs), min(ys), max(xs) + 1, max(ys) + 1]))
    return regions


def signatures(frame, width, box, along_rows, chunks):
    """Per row (or per column) of box [x0, y0, x1, y1], the mean brightness of
    `chunks` equal pieces of it: a row's coarse look, cheap to compare."""
    x0, y0, x1, y1 = box
    sigs = []
    if along_rows:
        edges = [x0 + (x1 - x0) * k // chunks for k in range(chunks + 1)]
        for y in range(y0, y1):
            line = frame[y * width:(y + 1) * width]
            sigs.append([sum(line[a:b]) / max(1, b - a) for a, b in zip(edges, edges[1:])])
        return sigs
    edges = [y0 + (y1 - y0) * k // chunks for k in range(chunks + 1)]
    columns = [[0] * (x1 - x0) for _ in range(chunks)]
    for k, (a, b) in enumerate(zip(edges, edges[1:])):
        acc = columns[k]
        for y in range(a, b):
            line = frame[y * width + x0:y * width + x1]
            for i, v in enumerate(line):
                acc[i] += v
        n = max(1, b - a)
        columns[k] = [v / n for v in acc]
    return [[columns[k][i] for k in range(chunks)] for i in range(x1 - x0)]


def best_offset(before, after, start, end, reach, tol, min_lines):
    """The offset d (|d| <= reach) at which after's lines start..end best match
    before's lines moved by d. Only lines that changed and carry something
    (not one flat colour) count. Returns (d, matched, counted) or None."""
    def differs(a, b):
        return max(abs(p - q) for p, q in zip(a, b)) > tol

    def textured(sig, neighbour):
        return max(sig) - min(sig) > tol or (neighbour is not None and differs(sig, neighbour))

    counted = [i for i in range(start, end)
               if differs(before[i], after[i]) and textured(after[i], after[i - 1] if i > 0 else None)]
    if len(counted) < min_lines:
        return None
    best = None
    for d in sorted(range(-reach, reach + 1), key=abs):
        if d == 0:
            continue
        matched = sum(1 for i in counted if 0 <= i - d < len(before) and not differs(after[i], before[i - d]))
        if best is None or matched > best[1]:
            best = (d, matched)
    if best is None or best[1] < max(min_lines, len(counted) / 2):
        return None
    return best[0], best[1], len(counted)


def shift_of(before, after, width, height, box, reach, tol, min_lines, chunks=8):
    """A move of the content in box (pixels) between two frames: (dx, dy) or None."""
    x0, y0, x1, y1 = box
    # Lines above or below the box may be where the content came from.
    vertical = [x0, max(0, y0 - reach), x1, min(height, y1 + reach)]
    rows_b = signatures(before, width, vertical, True, chunks)
    rows_a = signatures(after, width, vertical, True, chunks)
    found = best_offset(rows_b, rows_a, y0 - vertical[1], y1 - vertical[1], reach, tol, min_lines)
    if found:
        return 0, found[0]
    sideways = [max(0, x0 - reach), y0, min(width, x1 + reach), y1]
    cols_b = signatures(before, width, sideways, False, chunks)
    cols_a = signatures(after, width, sideways, False, chunks)
    found = best_offset(cols_b, cols_a, x0 - sideways[0], x1 - sideways[0], reach, tol, min_lines)
    if found:
        return found[0], 0
    return None


def moves(frame_list, series, width, height, cell, change, reach, tol, min_lines, min_cells):
    """Every (frame, box px, dx, dy) where a changed region is the earlier frame's content moved."""
    columns, rows = width // cell, height // cell
    found = []
    for i in range(1, len(series)):
        for count, (cx0, cy0, cx1, cy1) in changed_regions(series[i - 1], series[i], change, columns, rows):
            if count < min_cells:
                continue
            box = [cx0 * cell, cy0 * cell, cx1 * cell, cy1 * cell]
            shift = shift_of(frame_list[i - 1], frame_list[i], width, height, box, reach, tol, min_lines)
            if shift:
                found.append({"frame": i, "box": box, "dx": shift[0], "dy": shift[1]})
    return found


def overlaps(a, b, slack):
    return a[0] - slack < b[2] and b[0] - slack < a[2] and a[1] - slack < b[3] and b[1] - slack < a[3]


def jumps(found, glide_frames, gap, slack):
    """Moves of one area in nearby frames (gaps up to `gap`) are one event:
    two moves belong together when their boxes overlap and their frames are
    close, or when they are in one frame with one offset (a card's two edges
move as separate pieces), and so on transitively. An event is
    a glide when it spans glide_frames moving frames or more, else a jump."""
    found = sorted(found, key=lambda m: m["frame"])
    parent = list(range(len(found)))

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, a in enumerate(found):
        for j in range(i + 1, len(found)):
            b = found[j]
            if b["frame"] - a["frame"] > gap:
                break
            same_move = b["frame"] == a["frame"] and (b["dx"], b["dy"]) == (a["dx"], a["dy"])
            if same_move or overlaps(a["box"], b["box"], slack):
                parent[root(j)] = root(i)
    groups = {}
    for i, move in enumerate(found):
        groups.setdefault(root(i), []).append(move)
    out = []
    for moves_ in groups.values():
        frames_ = sorted({m["frame"] for m in moves_})
        # The move of the event: per frame, the largest region's offset, summed over frames.
        dx = dy = 0
        for f in frames_:
            biggest = max((m for m in moves_ if m["frame"] == f),
                          key=lambda m: (m["box"][2] - m["box"][0]) * (m["box"][3] - m["box"][1]))
            dx += biggest["dx"]
            dy += biggest["dy"]
        box = [min(m["box"][0] for m in moves_), min(m["box"][1] for m in moves_),
               max(m["box"][2] for m in moves_), max(m["box"][3] for m in moves_)]
        kind = "glide" if len(frames_) >= glide_frames else "jump"
        out.append({"kind": kind, "frame": frames_[0], "frames": frames_[-1] - frames_[0] + 1,
                    "moving_frames": len(frames_), "box": box, "dx": dx, "dy": dy, "cells": 0})
    return sorted(out, key=lambda e: e["frame"])


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
        filters += [f"fps={RATE}", f"select='between(n\\,{first}\\,{first + count - 1})'"]
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(path), "-vf", ",".join(filters),
                        "-vsync", "0", str(directory / f"{n:02d}-{event['kind']}-f%04d.png")], check=True)


FAILING = ("blink", "staggered", "jump")


def analyse(recording, crop=None, cell=6, change=6.0, blink_frames=6, settle_frames=18, steps=3, min_cells=1,
            glide_frames=4, min_shift=2.0, reach=48, shift_tol=6.0, min_lines=4):
    """The findings in one recording, as the JSON report's dict."""
    width, height, captured = probe(recording)
    fps = captured if recording.suffix == ".y4m" else RATE
    source_width, source_height = (crop[2], crop[3]) if crop else (width, height)
    grid = cell * GRID
    scaled_height = max(grid, round(source_height * WIDTH / source_width))
    frame_list = list(frames(recording, crop, WIDTH, scaled_height, RATE))
    series = [cell_means(f, WIDTH, scaled_height, grid) for f in frame_list]
    columns = WIDTH // grid
    scale = source_width / WIDTH
    events = merge(find(series, change, blink_frames), columns, grid, scale, fps)
    for event in staggered(series, change, settle_frames, steps, columns, grid):
        event["ms"], event["duration_ms"] = round(event["frame"] * 1000 / fps), round(event["frames"] * 1000 / fps)
        event["box"] = [round(v * scale) for v in event["box"]]
        del event["frames"]
        events.append(event)
    events = [e for e in events if e["cells"] >= min_cells]
    found = moves(frame_list, series, WIDTH, scaled_height, grid, change, reach, shift_tol, min_lines, 2)
    # Held frames of a variable-rate capture read as still frames between moves.
    gap = max(2, round(RATE / max(captured, 1)) + 1)
    for event in jumps(found, glide_frames, gap, grid):
        dx, dy = round(event["dx"] * scale), round(event["dy"] * scale)
        if max(abs(dx), abs(dy)) < min_shift:
            continue
        events.append({"kind": event["kind"], "frame": event["frame"], "ms": round(event["frame"] * 1000 / fps),
                       "duration_ms": round(event["frames"] * 1000 / fps), "cells": event["cells"],
                       "box": [round(v * scale) for v in event["box"]], "dx": dx, "dy": dy,
                       "moving_frames": event["moving_frames"]})
    events.sort(key=lambda e: (e["frame"], e["kind"]))
    counts = {kind: sum(1 for e in events if e["kind"] == kind) for kind in (*FAILING, "glide")}
    return {"recording": str(recording), "fps": round(fps, 2), "captured_fps": round(captured, 2),
            "frames": len(series), "counts": counts, "failing": sum(counts[k] for k in FAILING), "events": events}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("recording", type=Path)
    parser.add_argument("--crop", help="x,y,w,h in source pixels: the window or the control under test")
    parser.add_argument("--cell", type=int, default=6, help="grid cell size after scaling to 192 px wide")
    parser.add_argument("--change", type=float, default=6.0, help="mean brightness step (0-255) that counts")
    parser.add_argument("--blink-frames", type=int, default=6)
    parser.add_argument("--settle-frames", type=int, default=18)
    parser.add_argument("--steps", type=int, default=3)
    parser.add_argument("--min-cells", type=int, default=1, help="ignore blink/staggered events touching fewer cells")
    parser.add_argument("--glide-frames", type=int, default=4,
                        help="a move spread over this many frames or more is a glide, not a jump")
    parser.add_argument("--min-shift", type=float, default=2.0, help="source pixels a jump must move")
    parser.add_argument("--report-only", action="store_true", help="exit 0 whatever is found")
    parser.add_argument("--frames-dir", type=Path)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args(argv)

    crop = [int(v) for v in args.crop.split(",")] if args.crop else None
    result = analyse(args.recording, crop=crop, cell=args.cell, change=args.change, blink_frames=args.blink_frames,
                     settle_frames=args.settle_frames, steps=args.steps, min_cells=args.min_cells,
                     glide_frames=args.glide_frames, min_shift=args.min_shift)
    if result["captured_fps"] < 50:
        print(f"warning: captured at {result['captured_fps']:.1f} fps on average; a one-frame blink at 60 Hz can "
              "fall between frames", file=sys.stderr)
    for e in result["events"]:
        moved = f" moved=({e['dx']},{e['dy']})px" if "dx" in e else ""
        print(f"{e['kind']:<9} t={e['ms']}ms frame={e['frame']} lasts={e['duration_ms']}ms "
              f"cells={e['cells']} box={e['box']}" + (f" steps={e.get('steps')}" if e.get("steps") else "") + moved)
    counts = result["counts"]
    print(f"{len(result['events'])} events in {result['frames']} frames at {result['fps']:.1f} fps: "
          + ", ".join(f"{k} {v}" for k, v in counts.items()))
    if args.json:
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    if args.frames_dir and result["events"] and args.recording.suffix != ".y4m":
        dump(args.recording, crop, result["events"], args.frames_dir, result["fps"])
    return 0 if args.report_only or not result["failing"] else 1


if __name__ == "__main__":
    sys.exit(main())
