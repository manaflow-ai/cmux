"""How many visual stages a load showed: pure functions over recorded frames, so a test runs them on any host.

Leo, 2026-11-22 12:41Z: "loading chrome tabs. it has the transparent background. then it draws some asinine bullshit
idk opaque layer for a nasty-ass flicker. THEN loads the web page. in our app. nah. we can't have that. dont have
stupid multi stage loading." Measured on his NIGHTLY (dark theme): a cold Chromium tab shows the glass ground, ONE flat
frame of the theme's opaque page color (#1d1d2d), the glass again, then the page: 4 stages. A load may show 2 (the
ground, then the page): MAX_STAGES.

Frames are tab_switch_judge's: [(seconds, frame bytes)], one record per picture, w pixels wide, 8-bit gray (channels=1,
the recorder's) or RGB (channels=3); bytes, bytearray or anything with the buffer protocol (a uint8 numpy array).
Only the pane's region `rect` (x0, y0, x1, y1, end exclusive; the whole frame by default) is read, sampled on a grid
of about SAMPLES pixels. Two pictures are alike when their mean absolute difference (gray levels, 0 to 255) is at most
NOISE_MAD: capture and decode noise is a level or two, a glass ground against an opaque fill or a page is tens.

The rule. The frames after the mark that still equal `before` (the picture before the action: the old tab) are the
action not yet committed, and are no stage. The first frame after them is the ground G; the final frame P (the last
one, or `final`) is the page. Each later frame gets one kind, the first that fits:
  page    alike P; or a flat fill at P's own dominant level (the page's background painting before its text); or a
          frame closer to P than G is, by more than NOISE_MAD, that is not flat (the page painting progressively,
          a crossfade): a page that paints over ten frames is one stage, not ten
  ground  alike G (a return to the ground after another stage is a new stage: ground, X, ground, page is 4)
  before  alike the old tab's picture (it came back)
  flat    a flat fill (FLAT_SHARE of the samples within FLAT_SPREAD levels of their median) unlike G and P: the opaque
          frame of the bug, or a white flash, a stage even when it lasts ONE frame
  other   anything else (a spinner, an error page, a wrong tab)
Consecutive frames of one kind are one stage; a flat or other run splits where a frame is unlike the run's first
(white, then black, is two stages). Every stage, however short, counts: a stage that lasts one display frame is the
flicker Leo saw. count_stages returns the stages; verdict() says whether a load met MAX_STAGES.
"""
from __future__ import annotations

import math

NOISE_MAD = 4.0
FLAT_SPREAD = 6
FLAT_SHARE = 0.97
DOMINANT_SHARE = 0.5
SAMPLES = 4096
MAX_STAGES = 2
KINDS = ("ground", "page", "before", "flat", "other")


def _raw(frame):
    if isinstance(frame, (bytes, bytearray)):
        return bytes(frame)
    return memoryview(frame).tobytes()


class _Picture:
    """One frame's samples over the rect: gray levels, and the mean color."""

    __slots__ = ("gray", "mean", "flat", "median")

    def __init__(self, frame, w, rect, channels):
        data = _raw(frame)
        x0, y0, x1, y1 = rect
        step = max(1, int(math.sqrt(max(1, (x1 - x0) * (y1 - y0)) / SAMPLES)))
        gray = bytearray()
        sums = [0] * channels
        row_bytes = w * channels
        for y in range(y0, y1, step):
            base = y * row_bytes
            if channels == 1:
                gray += data[base + x0:base + x1:step]
            else:
                r = data[base + x0 * 3:base + x1 * 3:3 * step]
                g = data[base + x0 * 3 + 1:base + x1 * 3:3 * step]
                b = data[base + x0 * 3 + 2:base + x1 * 3:3 * step]
                gray += bytes((299 * rr + 587 * gg + 114 * bb) // 1000 for rr, gg, bb in zip(r, g, b))
                sums[0] += sum(r)
                sums[1] += sum(g)
                sums[2] += sum(b)
        self.gray = bytes(gray)
        n = max(1, len(self.gray))
        if channels == 1:
            level = sum(self.gray) / n
            self.mean = (round(level, 1),) * 3
        else:
            self.mean = tuple(round(s / n, 1) for s in sums)
        ordered = sorted(self.gray)
        self.median = ordered[len(ordered) // 2] if ordered else 0
        near = sum(1 for v in self.gray if abs(v - self.median) <= FLAT_SPREAD)
        self.flat = near / n >= FLAT_SHARE

    def dominant(self):
        """The level most of the picture shows (its median), None when no level covers DOMINANT_SHARE of it."""
        n = max(1, len(self.gray))
        near = sum(1 for v in self.gray if abs(v - self.median) <= FLAT_SPREAD)
        return self.median if near / n >= DOMINANT_SHARE else None


def mad(a, b):
    """The mean absolute gray difference between two pictures' samples (255.0 when their sizes differ)."""
    if len(a.gray) != len(b.gray) or not a.gray:
        return 255.0
    return sum(abs(x - y) for x, y in zip(a.gray, b.gray)) / len(a.gray)


def _covered(t, t_next, frame_ms):
    """Display frames a picture shown from t to t_next (seconds) covered: at least one (tab_switch_judge's rule)."""
    if not frame_ms:
        return 1
    return max(1, int(math.ceil(((t_next - t) * 1000 - 1.0) / frame_ms)))


def classify(pic, ground, page, before=None, noise=NOISE_MAD):
    """The kind (KINDS) of one picture against the ground, the page and the old tab's picture (module doc)."""
    to_page = mad(pic, page)
    if to_page <= noise:
        return "page"
    level = page.dominant()
    if pic.flat and level is not None and abs(pic.median - level) <= FLAT_SPREAD and mad(pic, ground) > noise:
        return "page"
    if mad(pic, ground) <= noise:
        return "ground"
    if before is not None and mad(pic, before) <= noise:
        return "before"
    if pic.flat:
        return "flat"
    if to_page < mad(ground, page) - noise:
        return "page"
    return "other"


def count_stages(frames, w, rect=None, mark=None, before=None, final=None, frame_ms=None, end=None, channels=1,
                 noise=NOISE_MAD):
    """The stages a load showed: [{"start_ms", "end_ms", "kind", "mean_rgb", "frames"}], times from `mark` (seconds;
    the first frame's time when None), frames in display frames of `frame_ms` (one per record when None).

    `frames` [(seconds, frame)]; with a mark, the frames at or before it are left out, and the last of them is
    `before` unless one is given. `final` is the page's settled frame (the last frame by default); `end` (seconds) the
    recording's end (the last frame's time plus one display frame by default)."""
    frames = sorted(frames, key=lambda f: f[0])
    if not frames:
        return []
    if rect is None:
        rect = (0, 0, w, len(_raw(frames[0][1])) // (w * channels))
    if mark is not None:
        earlier = [f for f in frames if f[0] <= mark]
        frames = [f for f in frames if f[0] > mark]
        if before is None and earlier:
            before = earlier[-1][1]
    else:
        mark = frames[0][0] if frames else 0.0
    if not frames:
        return []
    pics = [_Picture(f[1], w, rect, channels) for f in frames]
    old = _Picture(before, w, rect, channels) if before is not None else None
    start = 0
    if old is not None:
        while start < len(pics) and mad(pics[start], old) <= noise:
            start += 1
    if start == len(pics):
        return []
    times = [f[0] for f in frames]
    if end is None:
        end = times[-1] + (frame_ms or 0) / 1000
    ends = times[1:] + [max(end, times[-1])]
    ground = pics[start]
    page = _Picture(final, w, rect, channels) if final is not None else pics[-1]
    stages = []
    rep = None
    for i in range(start, len(pics)):
        kind = classify(pics[i], ground, page, old, noise) if i > start else (
            "page" if mad(ground, page) <= noise else "ground")
        last = stages[-1] if stages else None
        same = last is not None and last["kind"] == kind and (kind not in ("flat", "other") or mad(pics[i], rep) <= noise)
        n = _covered(times[i], ends[i], frame_ms)
        if same:
            last["end_ms"] = round((ends[i] - mark) * 1000, 2)
            last["frames"] += n
            continue
        rep = pics[i]
        stages.append({"start_ms": round((times[i] - mark) * 1000, 2), "end_ms": round((ends[i] - mark) * 1000, 2),
                       "kind": kind, "mean_rgb": list(pics[i].mean), "frames": n})
    return stages


def first_paint_ms(stages):
    """When the page's first stage started (ms from the mark), None when no stage shows the page."""
    return next((s["start_ms"] for s in stages if s["kind"] == "page"), None)


def verdict(stages, max_stages=MAX_STAGES):
    """True when the load showed at most `max_stages` stages (the ground, then the page)."""
    return len(stages) <= max_stages


def summary(stages):
    """The stages as one line: "ground 0-33ms > flat 33-50ms (1f) > ...", for logs and failure messages."""
    return " > ".join(f"{s['kind']} {s['start_ms']:.0f}-{s['end_ms']:.0f}ms ({s['frames']}f)" for s in stages)


def measure(frames, w, rect=None, mark=None, before=None, final=None, frame_ms=None, end=None, channels=1):
    """The per-switch fields the harness reports: load_stages (the count), first_paint_ms and the stage list."""
    stages = count_stages(frames, w, rect, mark, before, final, frame_ms, end, channels)
    return {"load_stages": len(stages), "first_paint_ms": first_paint_ms(stages), "stages": stages,
            "stages_summary": summary(stages)}
