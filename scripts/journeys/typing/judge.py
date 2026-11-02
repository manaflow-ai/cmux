#!/usr/bin/env python3
"""Typing key-to-photon from a 120 Hz screen video (VIDEO EXTRA item 1): display refreshes from each HID key-down to
the first frame that shows its character.

    judge.py --video CASE.mov --frames CASE.mov.frames.json --keys result.json[:STEP] --rect x,y,w,h [--scale 2]
             [--refresh-hz 120] [--out judge.json] [--self-test]

Inputs:
  --video     the HARNESS kit's movie (debug.motion record_*: the window 1:1 from its top-left, device pixels)
  --frames    PATH.frames.json beside it: every frame ScreenCaptureKit gave as [t, status, in_movie]; `t` the display
              time in host seconds (CACurrentMediaTime). The movie's frames are the rows with in_movie true, in order
  --keys      the journey's result.json; the `typing_keys` step's result (keys [{i, ch, t_post}], rect). STEP picks
              the step index when there are several
  --rect      the text's rect in window points from the top-left (default: the step's rect); --scale the backing
              scale (device pixels per point; default the recording's meta.json start.scale)

Method (robust when a glyph is late past the next key, which a per-key "first changed frame" is not): the keys type
into one left-aligned line, so the text grows to the right, one glyph per key. Reference = the still frame shown at
the first key. Band = the rows (and the columns from the leftmost one) that differ from the reference at the end of
the keys. Per frame: the reach = the rightmost band column that differs from the reference (any background works:
a terminal, a glass composer, a page's field). The final reach divided by the keys is the glyph advance A. Key i
(0-based) is shown in the first frame whose reach >= (i + 0.5) * A. Refreshes = vsync instants in (t_post, frame t]: 1 = the
next refresh. A cursor block moves with the text in a terminal (it stays solid while keys come; the start extent
is the most over the 0.5 s before the first key, so a blink-off then does not shift the count); defects are read only
from the first key to 0.5 s after the last.

Defects (each with the video time, seconds from the movie's first frame, and the frame index):
  late       refreshes > 1 (the order's target: the next refresh)
  shrink     the extent moves left by more than A/2 between two frames (a glyph vanished: a redraw from older state)
  blank      the band is flat (no ink at all) in a frame after the first glyph showed
Output: JSON {keys: [{i, ch, t_post, frame, t_frame, refreshes}], summary: {n, p50, p95, max, late}, defects}.
"""
import argparse
import json
import math
import subprocess
import sys
from pathlib import Path


def np():
    import numpy
    return numpy


def ffmpeg_exe():
    import shutil
    exe = shutil.which("ffmpeg")
    if exe:
        return exe
    import imageio_ffmpeg
    return imageio_ffmpeg.get_ffmpeg_exe()


def decode_band(video, crop):
    """Gray frames of the crop (x, y, w, h device pixels) of every stored frame, in movie order (no resampling)."""
    x, y, w, h = crop
    cmd = [ffmpeg_exe(), "-v", "error", "-i", str(video), "-vsync", "0", "-vf",
           f"crop={w}:{h}:{x}:{y},format=gray", "-f", "rawvideo", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    n = len(raw) // (w * h)
    return np().frombuffer(raw[: n * w * h], dtype=np().uint8).reshape(n, h, w)


def movie_times(frames_json):
    rows = json.loads(Path(frames_json).read_text())
    if isinstance(rows, dict):
        rows = rows.get("frames", [])
    return [float(r[0]) for r in rows if len(r) > 2 and r[2]]


def judge(frames, times, keys, refresh_hz=120.0, thresh=24):
    """Per frame, how far right the typed text reaches: the rightmost column that differs from the still frame
    before the first key (any background: a terminal, a glass field, a page), inside the band of rows that the keys
    changed. Key i shows in the first frame whose reach passed i + 1/2 glyphs."""
    n = np()
    period = 1.0 / refresh_hz
    if not keys:
        return {"error": "no keys"}
    t0 = keys[0]["t_post"]
    before = max([i for i, t in enumerate(times) if t <= t0] or [0])
    t_end = keys[-1]["t_post"] + 0.5
    end = max([i for i, t in enumerate(times) if t <= t_end] or [len(times) - 1])
    ref = frames[before].astype(n.int16)
    # The band: rows (and the columns' span) that changed from the reference to the end of the keys.
    last = n.abs(frames[end].astype(n.int16) - ref) > thresh
    rows = n.nonzero(last.any(axis=1))[0]
    cols = n.nonzero(last.any(axis=0))[0]
    if not rows.size:
        return {"error": "no pixel changed between the first key and the end (wrong rect, or no key showed)"}
    r0, r1, c0 = int(rows[0]), int(rows[-1]) + 1, int(cols[0])

    def reach(j):
        diff = n.abs(frames[j, r0:r1, c0:].astype(n.int16) - ref[r0:r1, c0:]) > thresh
        hit = n.nonzero(diff.any(axis=0))[0]
        return int(hit[-1]) + 1 if hit.size else 0
    ext = [reach(j) if before <= j <= end else 0 for j in range(len(frames))]
    grown = max(ext[before:end + 1])
    if grown <= 0:
        return {"error": "the text band shows no growth", "band": [r0, r1, c0]}
    advance = grown / len(keys)
    defects = []
    phase = float(n.median([t % period for t in times])) if times else 0.0
    rows_out, seen = [], before
    for k in keys:
        need = (k["i"] + 0.5) * advance
        idx = next((j for j in range(max(seen, before), end + 1) if times[j] > k["t_post"] and ext[j] >= need), None)
        if idx is None:
            rows_out.append(dict(k, frame=None, refreshes=None))
            continue
        seen = idx
        t = times[idx]
        first_vsync = math.floor((k["t_post"] - phase) / period) * period + phase + period
        refreshes = int(round((t - first_vsync) / period)) + 1
        rows_out.append(dict(k, frame=idx, t_frame=round(t, 6), video_s=round(t - times[0], 4), refreshes=refreshes))
        if refreshes > 1:
            defects.append({"kind": "late", "key": k["i"], "frame": idx, "video_s": round(t - times[0], 4),
                            "refreshes": refreshes})
    rows = rows_out
    first_shown = next((r["frame"] for r in rows if r.get("frame") is not None), None)
    for j in range(max(before + 1, 1), end + 1):
        if ext[j] < ext[j - 1] - advance / 2:
            defects.append({"kind": "shrink", "frame": j, "video_s": round(times[j] - times[0], 4),
                            "from": ext[j - 1], "to": ext[j]})
        if first_shown is not None and j > first_shown and ext[j] == 0 and ext[j - 1] > 0:
            defects.append({"kind": "blank", "frame": j, "video_s": round(times[j] - times[0], 4)})
    got = sorted(r["refreshes"] for r in rows if r.get("refreshes") is not None)

    def pct(p):
        return got[min(len(got) - 1, int(math.ceil(p / 100.0 * len(got))) - 1)] if got else None
    summary = {"n": len(keys), "shown": len(got), "p50": pct(50), "p95": pct(95), "max": got[-1] if got else None,
               "late": sum(1 for g in got if g > 1), "advance_px": round(advance, 2), "missing": len(keys) - len(got)}
    return {"keys": rows, "summary": summary, "defects": defects}


def self_test():
    """Synthetic: 10 keys 0.1 s apart; glyph i shows 1 refresh after its key, key 6 shows 3 refreshes late (after
    key 7's post), and one frame loses a glyph."""
    n = np()
    hz, period = 120.0, 1 / 120.0
    times = [i * period for i in range(200)]
    keys = [{"i": i, "ch": "n", "t_post": 0.05 + i * 0.1 + 0.001} for i in range(10)]
    show = {i: k["t_post"] + (3 * period if i == 6 else 0.5 * period) for i, k in enumerate(keys)}
    show[6] = keys[7]["t_post"] + 0.002  # late past the next key: shows with key 7
    frames = []
    for j, t in enumerate(times):
        count = sum(1 for i in range(10) if show[i] <= t)
        if j == 150:
            count -= 1  # a glyph vanishes for one frame
        f = n.zeros((10, 200), dtype=n.uint8)
        f[2:8, : 10 + 12 * count] = 200
        f[:, :10] = 0
        frames.append(f)
    out = judge(n.stack(frames), times, keys, hz)
    refr = {r["i"]: r["refreshes"] for r in out["keys"]}
    assert refr[0] == 1, refr
    assert refr[6] > 1 and refr[7] == 1, refr
    assert any(d["kind"] == "shrink" and d["frame"] == 150 for d in out["defects"]), out["defects"]
    assert out["summary"]["max"] == refr[6], out["summary"]
    print("self-test OK", json.dumps(out["summary"]))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--video"); ap.add_argument("--frames"); ap.add_argument("--keys")
    ap.add_argument("--rect"); ap.add_argument("--scale", type=float, help="device pixels per point (default: the "
                    "recording's meta.json start.scale beside the video, else 2)")
    ap.add_argument("--refresh-hz", type=float, default=120.0); ap.add_argument("--out")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        self_test()
        return 0
    path, _, pick = a.keys.partition(":")
    steps = [s for s in json.loads(Path(path).read_text()).get("steps", []) if s.get("do") == "typing_keys" and s.get("ok")]
    step = steps[int(pick)] if pick else steps[0]
    res = step["result"]
    rect = [float(v) for v in a.rect.split(",")] if a.rect else res["rect"]["rect_points_top_left"]
    scale = a.scale
    if scale is None:
        meta = Path(str(a.video)[:-4] + ".meta.json") if str(a.video).endswith(".mov") else None
        try:
            scale = float(json.loads(meta.read_text())["start"]["scale"])
        except (AttributeError, OSError, ValueError, KeyError, TypeError):
            scale = 2.0
    crop = [int(round(v * scale)) for v in rect]
    crop[2] -= crop[2] % 2
    crop[3] -= crop[3] % 2
    frames = decode_band(a.video, crop)
    times = movie_times(a.frames)
    if len(times) != len(frames):
        n = min(len(times), len(frames))
        frames, times = frames[:n], times[:n]
    out = judge(frames, times, res["keys"], a.refresh_hz)
    out["input"] = {"video": a.video, "crop_px": crop, "scale": scale, "label": res.get("label")}
    text = json.dumps(out, indent=1)
    if a.out:
        Path(a.out).write_text(text + "\n")
    print(json.dumps(out.get("summary") or out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
