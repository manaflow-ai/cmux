#!/usr/bin/env python3
"""Gap frames of a Chromium page in the films of `pane-perf-terminal.py --film` (Lawrence 2026-11-20: a zoomed AWS
console showed its old, narrower frame beside its backdrop for a few frames, then laid out again).

Each film is a movie of every frame the window server composited for the app (`debug.motion record_*`), with its
`.frames.json` (`[t, status, in movie]` per frame ScreenCaptureKit gave). The film's probe page has a magenta bar on
its own right and bottom edges, and the page's backdrop (the host view beside a page frame that is smaller than its
pane) takes the page's background color (#0b5d3b). In a frame where the page is laid out at its pane's size, the bars
touch the pane's edges; in a frame that shows the page's older, smaller frame, backdrop shows past a bar. A frame is a
gap frame when backdrop runs at least --min-px device pixels past the right bar (along the bar) or past the bottom bar.
Each movie frame shows until the next one, so a gap frame counts the display refreshes it showed (its time to the next
frame, at --hz).

Needs ffmpeg on PATH (the frames are decoded to raw RGB) and numpy. Usage:
  film-page-gap.py [--hz 120] [--min-px 6] [--json OUT] [--max-gap-refreshes N] FILM.mov [...]
Prints one line per film: gap refreshes, gap movie frames, the first and last gap time after the film's first change.
"""
import argparse, json, os, subprocess, sys

import numpy  # the frames as arrays: a pure-Python pass over every pixel of every frame takes minutes a film

def size_of(movie):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                          "-of", "csv=p=0", movie], capture_output=True, text=True, check=True).stdout.strip()
    width, height = (int(v) for v in out.split(",")[:2])
    return width, height


def frames(movie, scale):
    width, height = size_of(movie)
    w, h = width // scale, height // scale
    proc = subprocess.Popen(["ffmpeg", "-v", "error", "-i", movie, "-vf", f"scale={w}:{h}:flags=neighbor", "-vsync", "0",
                             "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    size = w * h * 3
    while True:
        buf = proc.stdout.read(size)
        if len(buf) < size:
            break
        yield w, h, buf
    proc.wait()


def gap_px(w, h, buf, scale):
    """Device pixels of backdrop past the page's right or bottom bar (the larger, median along the bar); None without
    a bar in the frame."""
    img = numpy.frombuffer(buf, dtype=numpy.uint8).reshape(h, w, 3).astype(numpy.int16)
    r, g, b = img[..., 0], img[..., 1], img[..., 2]
    magenta = (r > 190) & (g < 90) & (b > 190)
    backdrop = (abs(r - 0x0b) <= 16) & (abs(g - 0x5d) <= 18) & (abs(b - 0x3b) <= 16)
    rows = numpy.flatnonzero(magenta.any(axis=1))
    if rows.size == 0:
        return None
    # The rightmost magenta pixel of each row, and the lowest of each column: the page's right and bottom bars.
    right_of = w - 1 - numpy.argmax(magenta[:, ::-1], axis=1)
    cols = numpy.flatnonzero(magenta.any(axis=0))
    bottom_of = h - 1 - numpy.argmax(magenta[::-1, :], axis=0)
    right_edge = int(numpy.median(right_of[rows]))
    bottom = int(numpy.median(bottom_of[cols]))

    def run(line):
        """Leading backdrop pixels of `line`."""
        if line.size == 0 or not line[0]:
            return 0
        stop = numpy.argmin(line)
        return int(line.size if line[stop] else stop)
    rights = sorted(run(backdrop[y, right_of[y] + 1:]) for y in rows if abs(right_of[y] - right_edge) <= 1 and y < bottom - 2)
    bottoms = sorted(run(backdrop[bottom_of[x] + 1:, x]) for x in cols if abs(bottom_of[x] - bottom) <= 1 and x < right_edge - 2)
    med = lambda v: v[len(v) // 2] if v else 0
    return max(med(rights), med(bottoms)) * scale


def judge(movie, hz, min_px, scale):
    times_path = movie + ".frames.json"
    times = []
    if os.path.exists(times_path):
        listed = json.load(open(times_path))
        entries = listed.get("frames") if isinstance(listed, dict) else listed
        times = [float(e[0]) for e in entries or [] if isinstance(e, list) and len(e) >= 3 and e[2]]
    refresh = 1.0 / hz
    values = [gap_px(w, h, buf, scale) for w, h, buf in frames(movie, scale)]
    first_change = next((i for i in range(1, len(values)) if values[i] != values[0]), None)
    gaps, refreshes, shown = [], 0, []
    for i, value in enumerate(values):
        if value is None or value < min_px:
            continue
        if i + 1 < len(times) and i < len(times):
            span = max(1, round((times[i + 1] - times[i]) / refresh))
        else:
            span = 1
        gaps.append(i)
        refreshes += span
        if times and i < len(times):
            shown.append(round((times[i] - times[0]) * 1000, 1))
    return {"film": os.path.basename(movie), "movie_frames": len(values), "timed_frames": len(times),
            "gap_refreshes": refreshes, "gap_frames": len(gaps), "gap_ms_from_start": shown[:1] + shown[-1:],
            "first_change_frame": first_change, "max_gap_px": max([v for v in values if v is not None], default=None)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hz", type=float, default=120)
    parser.add_argument("--min-px", type=int, default=6)
    parser.add_argument("--scale", type=int, default=2, help="decode at 1/scale of the movie's size")
    parser.add_argument("--json")
    parser.add_argument("--max-gap-refreshes", type=int, help="exit 1 when any film has more gap refreshes than this")
    parser.add_argument("films", nargs="+")
    opts = parser.parse_args()
    results = [judge(movie, opts.hz, opts.min_px, opts.scale) for movie in opts.films]
    for result in results:
        print(json.dumps(result), flush=True)
    if opts.json:
        json.dump(results, open(opts.json, "w"), indent=1)
    if opts.max_gap_refreshes is not None:
        over = [r["film"] for r in results if r["gap_refreshes"] > opts.max_gap_refreshes]
        print(f"RESULT {'FAIL' if over else 'PASS'}: {len(over)} of {len(results)} films over {opts.max_gap_refreshes} gap refreshes"
              + (f" ({', '.join(over)})" if over else ""), flush=True)
        return 1 if over else 0


if __name__ == "__main__":
    sys.exit(main())
