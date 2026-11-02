#!/usr/bin/env python3
"""SHORTCUT FRAMES judge: key-to-photon in display refreshes, and frame defects, from a screen video.

For each HID key-down in a capture (the RESIZE VIDEOS kit: handoff/resize-videos/KIT.md), the judge finds the first
video frame that shows the key's visible change, counts the display refreshes from the key-down to that frame, and
checks the next frames for the defects the order names (Lawrence 2026-11-02: "open the new tab instantly, the frame
of ... ensure it's pixel perfect"): blank, flash, half-drawn chrome, layout jump, later re-layout, blink back.

Clock: the key-down time and the frame times must be on one clock (the host clock, mach_absolute_time in ns, which
ScreenCaptureKit's frame display times and CGEvent/IOHID timestamps use). A frame's time is the time the display
showed it (SCStreamFrameInfo.displayTime), not the time the file got it.

Definitions (P = the refresh period, from --refresh-hz; the vsync grid's phase comes from the frame times):
  before        the last frame shown at or before the key-down
  dynamic mask  8x8 blocks that changed in the --pre-ms before the key-down (busy panes, a blinking cursor), and
                --mask rectangles (the menu bar: AppKit highlights a menu title when a key equivalent fires)
  first frame   the first frame after the key-down with at least --min-blocks changed blocks outside the mask
  refreshes     vsync instants in (key-down, first frame's display time]: 1 = the next refresh (the order's rule)
  settled       the last frame within --settle-ms after the key-down (the action's end state)
  layout lines  long straight edges (pane borders, dividers, tab strip and toolbar edges): a column (row) whose
                longest run of strong horizontal (vertical) gradient is at least --line-px device pixels
Defects (each with its frame index and its time in the video, seconds from the movie's start):
  late          refreshes > 1
  half-drawn    the first frame's layout lines differ from the settled frame's (a line missing or extra); with
                --regions, a `chrome` region of the first frame that differs from the settled frame's
  re-layout     a layout line moves, appears or goes after the first frame (a not-animated effect), or moves back
                (an animated one: --animated)
  flash         a 32x32 cell whose mean luma leaves the envelope of its before and settled values by --flash-luma
  blank         a flat cell (luma spread under 2) whose mean is neither its before nor its settled value
  blink-back    a frame after the first that equals the before frame again (outside the mask)
Content that loads later (a shell prompt, a web page) is no defect: it changes pixels inside its region without
moving a layout line, and the settled frame has it.

Inputs:
  --video CASE.mov    the capture (any ffmpeg-readable file; decoded at its stored frames, no resampling)
  --frames FILE       the kit's MOVIE.frames.json (debug.screen_record: [t host seconds, status, in_movie] per frame;
                      the in_movie frames are the movie's, in order), or a CSV / JSON-lines file with `display_ns` per
                      stored frame; else --pts-offset-ns maps the movie's pts to the host clock
  --hid FILE          JSON lines, one per HID event: {"t_ns": host ns (or "t": host seconds), "phase": "down"|"up", "key": "t",
                      "mods": ["cmd"], "label": "case/press"}; only key-downs with a label are judged
  --crop x,y,w,h      the window's rectangle in capture pixels (default: the whole frame)
  --regions FILE      optional JSON [{"name", "kind": "chrome"|"content", "rect": [x, y, w, h]}] in capture pixels,
                      from the app's topology after the action
Output: JSON (one row per key-down, and a summary) to stdout or --out.

  judge.py --video case.mov --frames frames.csv --hid hid.ndjson --refresh-hz 120 [--animated] [--out judge.json]
  judge.py --self-test       (synthetic frames: a clean press, a late one, a flash, a re-layout, a blink-back)

Needs numpy and ffmpeg (ffmpeg on PATH, or the imageio-ffmpeg package's binary).
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import shutil
import subprocess
import sys
from dataclasses import dataclass, field

import numpy as np

BLOCK = 8
CELL = 32


@dataclass
class Settings:
    refresh_hz: float = 120.0
    pre_ms: float = 1500.0
    post_ms: float = 1000.0
    settle_ms: float = 800.0
    block_diff: float = 3.0       # mean abs luma difference of an 8x8 block that counts as changed
    min_blocks: int = 2
    edge: int = 24                # gradient that counts as an edge (luma levels)
    line_px: int = 96             # longest edge run that makes a layout line
    flash_luma: float = 14.0
    animated: bool = False
    masks: list = field(default_factory=list)
    regions: list = field(default_factory=list)


def luma(rgb: np.ndarray) -> np.ndarray:
    return (rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722).astype(np.float32)


def block_means(diff: np.ndarray, size: int) -> np.ndarray:
    h, w = diff.shape
    h2, w2 = h // size * size, w // size * size
    return diff[:h2, :w2].reshape(h2 // size, size, w2 // size, size).mean(axis=(1, 3))


def block_spread(img: np.ndarray, size: int) -> np.ndarray:
    h, w = img.shape
    h2, w2 = h // size * size, w // size * size
    v = img[:h2, :w2].reshape(h2 // size, size, w2 // size, size)
    return v.max(axis=(1, 3)) - v.min(axis=(1, 3))


def longest_runs(mask: np.ndarray, axis: int) -> np.ndarray:
    """Longest run of True along `axis` for every line across it."""
    m = mask if axis == 0 else mask.T
    best = np.zeros(m.shape[1], dtype=np.int32)
    run = np.zeros(m.shape[1], dtype=np.int32)
    for row in m:
        run = np.where(row, run + 1, 0)
        np.maximum(best, run, out=best)
    return best


def layout_lines(img: np.ndarray, s: Settings, keep: np.ndarray) -> tuple[tuple[int, ...], tuple[int, ...]]:
    """(x of vertical lines, y of horizontal lines): long straight edges outside the dynamic mask."""
    gx = np.zeros_like(img)
    gy = np.zeros_like(img)
    gx[:, 1:] = np.abs(img[:, 1:] - img[:, :-1])
    gy[1:, :] = np.abs(img[1:, :] - img[:-1, :])
    vertical = longest_runs((gx >= s.edge) & keep, axis=0)
    horizontal = longest_runs((gy >= s.edge) & keep, axis=1)
    return (tuple(int(x) for x in np.nonzero(vertical >= s.line_px)[0]),
            tuple(int(y) for y in np.nonzero(horizontal >= s.line_px)[0]))


def line_change(a: tuple, b: tuple) -> dict:
    sa, sb = set(a), set(b)
    return {"added": sorted(sb - sa)[:12], "removed": sorted(sa - sb)[:12]}


def static_pixels(dynamic_blocks: np.ndarray, shape: tuple[int, int], s: Settings, crop: tuple) -> np.ndarray:
    keep = np.ones(shape, dtype=bool)
    grown = dynamic_blocks.copy()
    # One block of margin: a busy pane's edge pixels and its antialiasing.
    grown[1:, :] |= dynamic_blocks[:-1, :]
    grown[:-1, :] |= dynamic_blocks[1:, :]
    grown[:, 1:] |= grown[:, :-1].copy()
    grown[:, :-1] |= grown[:, 1:].copy()
    ys, xs = np.nonzero(grown)
    for y, x in zip(ys, xs):
        keep[y * BLOCK:(y + 1) * BLOCK, x * BLOCK:(x + 1) * BLOCK] = False
    cx, cy = crop[0], crop[1]
    for (x, y, w, h) in s.masks:
        keep[max(0, y - cy):max(0, y - cy + h), max(0, x - cx):max(0, x - cx + w)] = False
    return keep


class Vsync:
    def __init__(self, times_ns: list[int], hz: float):
        self.period = 1e9 / hz
        phases = [(t % self.period) / self.period * 2 * math.pi for t in times_ns] or [0.0]
        angle = math.atan2(sum(math.sin(p) for p in phases), sum(math.cos(p) for p in phases))
        self.phase = (angle % (2 * math.pi)) / (2 * math.pi) * self.period

    def refreshes(self, key_ns: int, frame_ns: int) -> int:
        """Vsync instants in (key_ns, frame_ns]."""
        return math.floor((frame_ns - self.phase) / self.period + 0.5) - math.floor((key_ns - self.phase) / self.period)


def judge_press(key_ns: int, label: str, frames: list[tuple[int, float, np.ndarray]], s: Settings,
                vsync: Vsync, crop: tuple) -> dict:
    """frames: (display_ns, movie_seconds, rgb) from --pre-ms before the key to --post-ms after it."""
    pre = [f for f in frames if f[0] <= key_ns]
    post = [f for f in frames if f[0] > key_ns]
    row: dict = {"label": label, "key_ns": key_ns, "defects": []}
    if not pre or not post:
        row["error"] = "no frame before or after the key-down in the capture"
        return row
    gray_pre = [luma(f[2]) for f in pre]
    before = gray_pre[-1]
    dynamic = np.zeros(block_means(before, BLOCK).shape, dtype=bool)
    for a, b in zip(gray_pre, gray_pre[1:]):
        dynamic |= block_means(np.abs(b - a), BLOCK) >= s.block_diff
    keep = static_pixels(dynamic, before.shape, s, crop)
    keep_blocks = block_means(keep.astype(np.float32), BLOCK) >= 0.999
    gray_post = [luma(f[2]) for f in post]

    settle_ns = key_ns + s.settle_ms * 1e6
    settled_i = max(i for i, f in enumerate(post) if f[0] <= settle_ns) if post[0][0] <= settle_ns else 0
    settled = gray_post[settled_i]

    first = None
    for i, img in enumerate(gray_post):
        changed = (block_means(np.abs(img - before), BLOCK) >= s.block_diff) & keep_blocks
        if int(changed.sum()) >= s.min_blocks:
            first = i
            break
    row["dynamic_blocks"] = int(dynamic.sum())
    if first is None:
        row["first_frame"] = None
        row["defects"].append({"kind": "no-change", "detail": f"no frame within {s.post_ms:.0f} ms changed outside the mask"})
        return row
    t_first, sec_first, _ = post[first]
    n = vsync.refreshes(key_ns, t_first)
    row.update({"first_frame_ms": round((t_first - key_ns) / 1e6, 2), "refreshes": n,
                "movie_s": round(sec_first, 4), "settled_ms": round((post[settled_i][0] - key_ns) / 1e6, 2)})
    if n > 1:
        row["defects"].append({"kind": "late", "movie_s": round(sec_first, 4),
                               "detail": f"first change at refresh {n} ({row['first_frame_ms']} ms after the key-down)"})

    # Layout: the first frame against the settled frame, then every later frame against the one before it.
    lines = [layout_lines(img, s, keep) for img in gray_post[first:settled_i + 1]] or [layout_lines(gray_post[first], s, keep)]
    final = layout_lines(settled, s, keep)
    if lines[0] != final and not s.animated:
        row["defects"].append({"kind": "half-drawn", "movie_s": round(sec_first, 4),
                               "detail": {"vertical": line_change(final[0], lines[0][0]),
                                          "horizontal": line_change(final[1], lines[0][1]),
                                          "meaning": "lines in the first frame that the settled frame does not have "
                                                     "(added) or lacks (removed)"}})
    last_direction: dict = {}
    for j in range(1, len(lines)):
        if lines[j] == lines[j - 1]:
            continue
        idx = first + j
        change = {"vertical": line_change(lines[j - 1][0], lines[j][0]),
                  "horizontal": line_change(lines[j - 1][1], lines[j][1])}
        if not s.animated:
            row["defects"].append({"kind": "re-layout", "movie_s": round(post[idx][1], 4),
                                   "refresh": vsync.refreshes(key_ns, post[idx][0]), "detail": change})
            continue
        # Animated: a line may move toward its end, never back.
        for axis in ("vertical", "horizontal"):
            add, rem = change[axis]["added"], change[axis]["removed"]
            if add and rem:
                step = (sum(add) / len(add)) - (sum(rem) / len(rem))
                sign = 1 if step > 0 else -1
                if last_direction.get(axis, sign) != sign:
                    row["defects"].append({"kind": "jump-back", "movie_s": round(post[idx][1], 4), "axis": axis,
                                           "refresh": vsync.refreshes(key_ns, post[idx][0]), "detail": change[axis]})
                last_direction[axis] = sign

    # Flash and blank per cell; blink back to the before frame.
    cell_keep = block_means(keep.astype(np.float32), CELL) >= 0.999
    b_cells, s_cells = block_means(before, CELL), block_means(settled, CELL)
    low, high = np.minimum(b_cells, s_cells) - s.flash_luma, np.maximum(b_cells, s_cells) + s.flash_luma
    s_spread, b_spread = block_spread(settled, CELL), block_spread(before, CELL)
    flagged_flash = flagged_blank = False
    for i in range(first, settled_i + 1):
        img = gray_post[i]
        cells = block_means(img, CELL)
        out = ((cells < low) | (cells > high)) & cell_keep
        if out.any() and not flagged_flash:
            ys, xs = np.nonzero(out)
            row["defects"].append({"kind": "flash", "movie_s": round(post[i][1], 4),
                                   "refresh": vsync.refreshes(key_ns, post[i][0]), "cells": int(out.sum()),
                                   "at_px": [int(xs[0]) * CELL + crop[0], int(ys[0]) * CELL + crop[1]]})
            flagged_flash = True
        flat = block_spread(img, CELL) < 2
        odd = flat & cell_keep & (np.abs(cells - b_cells) > s.flash_luma) & (np.abs(cells - s_cells) > s.flash_luma)
        odd &= (s_spread >= 2) | (b_spread >= 2) | (np.abs(cells - s_cells) > s.flash_luma)
        if odd.sum() >= 2 and not flagged_blank:
            ys, xs = np.nonzero(odd)
            row["defects"].append({"kind": "blank", "movie_s": round(post[i][1], 4),
                                   "refresh": vsync.refreshes(key_ns, post[i][0]), "cells": int(odd.sum()),
                                   "at_px": [int(xs[0]) * CELL + crop[0], int(ys[0]) * CELL + crop[1]]})
            flagged_blank = True
        if i > first:
            back = (block_means(np.abs(img - before), BLOCK) >= s.block_diff) & keep_blocks
            if int(back.sum()) < s.min_blocks:
                row["defects"].append({"kind": "blink-back", "movie_s": round(post[i][1], 4),
                                       "refresh": vsync.refreshes(key_ns, post[i][0])})
                break

    # Chrome regions (from the app's topology): the first frame must already be the settled chrome.
    for region in s.regions:
        if region.get("kind") != "chrome":
            continue
        x, y, w, h = region["rect"]
        x, y = x - crop[0], y - crop[1]
        a = gray_post[first][y:y + h, x:x + w]
        b = settled[y:y + h, x:x + w]
        if a.size and float(np.abs(a - b).mean()) >= s.block_diff / 2:
            row["defects"].append({"kind": "half-drawn", "movie_s": round(sec_first, 4), "region": region["name"],
                                   "detail": f"mean luma difference {float(np.abs(a - b).mean()):.1f} from the settled chrome"})
    row["pass"] = not row["defects"]
    return row


# MARK: Reading a capture

def ffmpeg_exe() -> str:
    exe = shutil.which("ffmpeg")
    if exe:
        return exe
    try:
        import imageio_ffmpeg  # type: ignore
        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        sys.exit("judge: needs ffmpeg on PATH or the imageio-ffmpeg package")


def movie_frames(path: str, crop: tuple | None):
    """(pts seconds, rgb) of every stored frame, in order (no resampling)."""
    exe = ffmpeg_exe()
    probe = subprocess.run([exe, "-hide_banner", "-i", path], capture_output=True, text=True).stderr
    import re
    m = re.search(r"Video: .*?, (\d{2,5})x(\d{2,5})", probe)
    if not m:
        sys.exit(f"judge: cannot read the video size of {path}")
    width, height = int(m.group(1)), int(m.group(2))
    filters = ["showinfo"]
    x, y, w, h = crop or (0, 0, width, height)
    if crop:
        filters.insert(0, f"crop={w}:{h}:{x}:{y}")
    proc = subprocess.Popen([exe, "-v", "info", "-hide_banner", "-i", path, "-vf", ",".join(filters),
                             "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    size = w * h * 3
    import threading
    pts: list[float] = []

    def read_info():
        for line in proc.stderr:  # type: ignore[union-attr]
            mm = re.search(rb"pts_time:\s*([-0-9.]+)", line)
            if mm:
                pts.append(float(mm.group(1)))
    t = threading.Thread(target=read_info, daemon=True)
    t.start()
    n = 0
    while True:
        buf = proc.stdout.read(size)  # type: ignore[union-attr]
        if len(buf) < size:
            break
        while len(pts) <= n and t.is_alive():
            t.join(0.01)
        yield (pts[n] if n < len(pts) else float("nan")), np.frombuffer(buf, np.uint8).reshape(h, w, 3)
        n += 1
    proc.wait()


def read_rows(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if text.lstrip().startswith("{"):
        return [json.loads(line) for line in text.splitlines() if line.strip()]
    return list(csv.DictReader(text.splitlines()))


def movie_display_ns(path: str) -> list[int]:
    """The host-clock display time of each frame in the movie, in movie order.

    Reads the kit's `MOVIE.frames.json` (`debug.screen_record`: {"frames": [[t host seconds, status, in_movie], ...]};
    only frames with in_movie true are in the movie) or a CSV / JSON-lines file with a `display_ns` column."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if text.lstrip().startswith("{") and '"frames"' in text[:200]:
        try:
            frames = json.loads(text)["frames"]
            return [int(round(float(t) * 1e9)) for t, _status, in_movie in frames if in_movie]
        except (json.JSONDecodeError, ValueError, KeyError):
            pass
    return [int(float(r["display_ns"])) for r in read_rows(path)]


def run(args: argparse.Namespace, s: Settings) -> dict:
    crop = tuple(int(v) for v in args.crop.split(",")) if args.crop else None
    keys = [r for r in read_rows(args.hid) if r.get("phase", "down") == "down" and r.get("label")]
    for r in keys:
        r["t_ns"] = int(r["t_ns"]) if "t_ns" in r else int(round(float(r["t"]) * 1e9))
    keys.sort(key=lambda r: r["t_ns"])
    display = movie_display_ns(args.frames) if args.frames else None
    rows, k = [], 0
    window: list[tuple[int, float, np.ndarray]] = []
    all_times: list[int] = []
    pending: list[tuple[int, str]] = [(int(r["t_ns"]), r["label"]) for r in keys]
    for n, (pts, rgb) in enumerate(movie_frames(args.video, crop)):
        t = display[n] if display is not None and n < len(display) else int(args.pts_offset_ns + pts * 1e9)
        all_times.append(t)
        window.append((t, pts, rgb))
        lo = (pending[k][0] if k < len(pending) else t) - s.pre_ms * 1e6
        window = [f for f in window if f[0] >= lo or f is window[-1]]
        while k < len(pending) and t > pending[k][0] + s.post_ms * 1e6:
            key_ns, label = pending[k]
            frames = [f for f in window if key_ns - s.pre_ms * 1e6 <= f[0] <= key_ns + s.post_ms * 1e6]
            rows.append(judge_press(key_ns, label, frames, s, Vsync(all_times[-2000:], s.refresh_hz), crop or (0, 0)))
            k += 1
    while k < len(pending):
        key_ns, label = pending[k]
        frames = [f for f in window if key_ns - s.pre_ms * 1e6 <= f[0] <= key_ns + s.post_ms * 1e6]
        rows.append(judge_press(key_ns, label, frames, s, Vsync(all_times[-2000:], s.refresh_hz), crop or (0, 0)))
        k += 1
    return {"video": args.video, "refresh_hz": s.refresh_hz, "presses": rows, "summary": summarize(rows)}


def pct(values: list[float], q: float) -> float | None:
    if not values:
        return None
    v = sorted(values)
    return v[min(len(v) - 1, max(0, math.ceil(q * len(v)) - 1))]


def summarize(rows: list[dict]) -> dict:
    """p50/p95/max of refreshes per case (the label up to its last `/`), and the defect counts."""
    by_case: dict[str, list[dict]] = {}
    for r in rows:
        by_case.setdefault(r["label"].rsplit("/", 1)[0], []).append(r)
    out = {}
    for case, items in sorted(by_case.items()):
        n = [r["refreshes"] for r in items if r.get("refreshes") is not None]
        kinds: dict[str, int] = {}
        for r in items:
            for d in r["defects"]:
                kinds[d["kind"]] = kinds.get(d["kind"], 0) + 1
        out[case] = {"presses": len(items), "refreshes_p50": pct(n, 0.5), "refreshes_p95": pct(n, 0.95),
                     "refreshes_max": max(n) if n else None, "defects": kinds,
                     "pass": all(r.get("pass") for r in items)}
    return out


# MARK: Self-test on synthetic frames

def self_test() -> int:
    hz, period = 120.0, int(1e9 / 120)
    w, h = 320, 200
    base = np.full((h, w, 3), 30, np.uint8)
    base[:, 159:161] = 200          # a divider: one vertical layout line
    base[20:22, :] = 200            # a tab strip edge: one horizontal layout line

    def new_tab(img):
        out = img.copy()
        out[0:20, 161:240] = 90      # the new selected tab in the strip
        out[22:, 161:] = 40          # the new surface's background
        return out

    def clip(case: str, first_refresh: int, extra=None):
        frames, t0 = [], 1_000_000_000
        key = t0 + 30 * period + period // 3
        for i in range(0, 90):
            t = t0 + i * period
            img = base if t <= key else (new_tab(base) if t >= t0 + (30 + first_refresh) * period else base)
            if extra:
                img = extra(i - 30, img)
            frames.append((t, i / hz, img))
        return key, frames

    s = Settings(refresh_hz=hz, line_px=60, pre_ms=200, post_ms=500, settle_ms=400)
    results = {}

    def check(name, key, frames, s=s):
        vs = Vsync([f[0] for f in frames], hz)
        results[name] = judge_press(key, name, frames, s, vs, (0, 0))

    check("clean", *clip("clean", 1))
    check("late", *clip("late", 3))

    def flash(i, img):
        if i == 1:
            img = img.copy()
            img[22:, 161:] = 250
        return img
    check("flash", *clip("flash", 1, flash))

    def relayout(i, img):
        if i >= 4 and i >= 1:
            img = img.copy()
            img[:, 159:161] = 30
            img[:, 199:201] = 200     # the divider moves after the first frame
        return img
    check("re-layout", *clip("re-layout", 1, relayout))

    def blink(i, img):
        return base if i == 2 else img
    check("blink-back", *clip("blink-back", 1, blink))

    def busy(i, img):
        img = img.copy()
        img[100:160, 10:120] = (i * 37) % 255   # a busy pane outside the change
        return img
    check("busy", *clip("busy", 1, busy))

    want = {"clean": (1, set()), "late": (3, {"late"}), "flash": (1, {"flash"}), "re-layout": (1, {"re-layout"}),
            "blink-back": (1, {"blink-back"}), "busy": (1, set())}
    ok = True
    for name, (refreshes, kinds) in want.items():
        got = results[name]
        got_kinds = {d["kind"] for d in got["defects"]}
        good = got.get("refreshes") == refreshes and kinds <= got_kinds and bool(kinds or not got_kinds)
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'} {name}: refreshes {got.get('refreshes')}, defects {sorted(got_kinds)}")
    return 0 if ok else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--video")
    p.add_argument("--frames")
    p.add_argument("--hid")
    p.add_argument("--pts-offset-ns", type=float, default=0.0)
    p.add_argument("--refresh-hz", type=float, default=120.0)
    p.add_argument("--crop")
    p.add_argument("--mask", action="append", default=[], help="x,y,w,h in capture pixels to ignore (repeatable)")
    p.add_argument("--regions")
    p.add_argument("--animated", action="store_true", help="the effect animates: layout lines may move toward their end")
    p.add_argument("--pre-ms", type=float, default=1500.0)
    p.add_argument("--post-ms", type=float, default=1000.0)
    p.add_argument("--settle-ms", type=float, default=800.0)
    p.add_argument("--line-px", type=int, default=96)
    p.add_argument("--out")
    p.add_argument("--self-test", action="store_true")
    a = p.parse_args()
    if a.self_test:
        return self_test()
    if not (a.video and a.hid):
        p.error("--video and --hid are required")
    s = Settings(refresh_hz=a.refresh_hz, pre_ms=a.pre_ms, post_ms=a.post_ms, settle_ms=a.settle_ms,
                 line_px=a.line_px, animated=a.animated,
                 masks=[tuple(int(v) for v in m.split(",")) for m in a.mask],
                 regions=json.load(open(a.regions)) if a.regions else [])
    report = run(a, s)
    text = json.dumps(report, indent=1)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    else:
        print(text)
    return 0 if all(c["pass"] for c in report["summary"].values()) else 1


if __name__ == "__main__":
    sys.exit(main())
