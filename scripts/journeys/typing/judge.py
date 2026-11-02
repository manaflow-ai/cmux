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


def judge(frames, times, keys, refresh_hz=120.0, thresh=24, max_band_px=96):
    """Per frame, how far right the typed text reaches (the rightmost column that differs from the still frame shown
    at the first key, inside the text line's band), and when each key's glyph first shows.

    The line is fitted from two robust numbers, never from a single early frame (a caret or cursor that blinks near
    the first key would shift it: review must-fix 1 at af4a0cb661d and at 208cfb19c5d):
      RN  the reach once every glyph shows: the most over the last 0.25 s of the keys' span;
      A   the glyph advance: the median of the steps between the reach's successive plateaus (two glyphs that come
          in one frame make one double step, which the median ignores).
    With a caret or cursor of width w after the text, the reach after k glyphs is k A + w, so glyph i shows when
    reach >= RN - (N - 1 - i) A - A / 2, whatever w is. The band: the rows of the end frame's change that hold at
    least a quarter of its busiest row's changed pixels (the text line, not a button or a title elsewhere), from its
    leftmost changed column."""
    n = np()
    period = 1.0 / refresh_hz
    if len(keys) < 2:
        return {"error": "need at least 2 keys"}
    t0 = keys[0]["t_post"]
    before = max([i for i, t in enumerate(times) if t <= t0] or [0])
    t_end = keys[-1]["t_post"] + 0.5
    end = max([i for i, t in enumerate(times) if t <= t_end] or [len(times) - 1])
    ref = frames[before].astype(n.int16)
    m = n.abs(frames[end].astype(n.int16) - ref) > thresh
    per_row = m.sum(axis=1)
    if not per_row.any():
        return {"error": "no pixel changed between the first key and the end (wrong rect, or no key showed)"}
    rows = n.nonzero(per_row >= max(1, per_row.max() // 4))[0]
    r0, r1 = int(rows[0]), int(rows[-1]) + 1
    cols = n.nonzero(m[r0:r1].any(axis=0))[0]
    c0 = int(cols[0])
    band = {"rows": [r0, r1], "left": c0}
    if r1 - r0 > max_band_px:
        return {"error": f"band unclear: the text line's change spans {r1 - r0} rows (> {max_band_px})", "band": band}

    def reach(j):
        diff = n.abs(frames[j, r0:r1, c0:].astype(n.int16) - ref[r0:r1, c0:]) > thresh
        hit = n.nonzero(diff.any(axis=0))[0]
        return int(hit[-1]) + 1 if hit.size else 0
    ext = [reach(j) if before <= j <= end else 0 for j in range(len(frames))]
    tail = [ext[j] for j in range(before, end + 1) if times[j] >= t_end - 0.25] or [ext[end]]
    r_end = max(tail)
    # Plateaus: values the reach holds for at least 1.5 refreshes, in time order. Measured by time, not by frames:
    # the kit's movie keeps only changed frames (an idle refresh has no movie frame), so a still line between two
    # keys is ONE movie frame (review must-fix 2 at 9e4af2272ba).
    plateaus, run_v, run_t = [], None, None
    for j in range(before, end + 1):
        if ext[j] != run_v:
            if run_v is not None and times[j] - run_t >= 1.5 * period:
                plateaus.append(run_v)
            run_v, run_t = ext[j], times[j]
    if run_v is not None and times[end] + period - run_t >= 1.5 * period:
        plateaus.append(run_v)
    steps = [b - a for a, b in zip(plateaus, plateaus[1:]) if b > a]
    if not steps:
        return {"error": "the text band shows no growth", "band": band}
    advance = float(n.median(steps))
    if advance <= 0:
        return {"error": "the text band shows no growth", "band": band}
    band.update(advance_px=round(advance, 2), reach_end_px=r_end, plateaus=len(plateaus))
    defects = []
    phase = float(n.median([t % period for t in times])) if times else 0.0
    rows_out, seen = [], before
    count = len(keys)
    for k in keys:
        need = r_end - (count - 1 - k["i"]) * advance - advance / 2
        idx = next((j for j in range(max(seen, before + 1), end + 1) if times[j] > k["t_post"] and ext[j] >= need), None)
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
    return {"keys": rows, "summary": summary, "defects": defects, "band": band}


def _synthetic(n_keys, late_refreshes, cursor, late_key=None, vanish=None, noise_right=False, caret_blink=None,
               gap=0.1):
    """Synthetic frames of a typed line: glyph i (12 px) appears LATE_REFRESHES refreshes after its key (key
    LATE_KEY: after the next key), frames every refresh. CURSOR: "block" (12 px after the text) or "caret" (2 px);
    CARET_BLINK: the cursor is off at the first key and comes on CARET_BLINK s after it (before glyph 0)."""
    n = np()
    period = 1 / 120.0
    times = [i * period for i in range(int((n_keys * gap + 0.7) / period))]
    keys = [{"i": i, "ch": "n", "t_post": 0.05 + i * gap + 0.0011} for i in range(n_keys)]
    # Glyph i shows at the LATE_REFRESHES-th refresh after its key (1 = the next refresh), on the frames' grid.
    show = {i: (math.floor(k["t_post"] / period + 1e-9) + late_refreshes) * period - 1e-6 for i, k in enumerate(keys)}
    if late_key is not None:
        show[late_key] = keys[late_key + 1]["t_post"] + 0.002
    frames = []
    for j, t in enumerate(times):
        count = sum(1 for i in range(n_keys) if show[i] <= t)
        if vanish is not None and j == vanish:
            count -= 1
        f = n.zeros((20, 400), dtype=n.uint8)
        f[4:16, 10: 10 + 12 * count] = 200
        on = True
        if caret_blink is not None and count == 0:
            on = t < keys[0]["t_post"] - 0.3 or t >= keys[0]["t_post"] + caret_blink
        if cursor and on:
            width = 12 if cursor == "block" else 2
            f[2:18, 10 + 12 * count: 10 + 12 * count + width] = 120
        if noise_right and j % 30 == 0:
            f[0:2, 390:400] = 255  # a spinner far right, in other rows
        frames.append(f)
    return n.stack(frames), times, keys


def self_test():
    def refr(out):
        return [r["refreshes"] for r in out["keys"]]
    # 1. a clean line, a glyph late past the next key, a glyph that vanishes for one frame
    frames, times, keys = _synthetic(10, 1, cursor=None, late_key=6, vanish=150)
    out = judge(frames, times, keys)
    got = refr(out)
    assert got[0] == 1 and got[6] > 1 and got[7] == 1, got
    assert any(d["kind"] == "shrink" for d in out["defects"]), out["defects"]
    # 2. a block cursor, every glyph 3 refreshes late: every key reads 3 (review must-fix 1 at af4a0cb661d)
    out = judge(*_synthetic(20, 3, cursor="block"))
    assert all(g == 3 for g in refr(out)), refr(out)
    # 3. on time, a block cursor and a spinner elsewhere: every key reads 1
    out = judge(*_synthetic(20, 1, cursor="block", noise_right=True))
    assert all(g == 1 for g in refr(out)), (refr(out), out.get("band"))
    # 4. a caret off at the first key that blinks on before glyph 0, glyphs 3 late (review must-fix 1 at 208cfb19c5d)
    out = judge(*_synthetic(20, 3, cursor="caret", caret_blink=0.005))
    assert all(g == 3 for g in refr(out)), refr(out)
    # 5. the same with a block cursor and keys 0.27 s apart (a pause not near a blink period)
    out = judge(*_synthetic(12, 3, cursor="block", caret_blink=0.004, gap=0.27))
    assert all(g == 3 for g in refr(out)), refr(out)
    # 6. the movie keeps only frames that differ from the one before (idle refreshes are not in it): same results
    for late, cursor in ((1, "block"), (3, "block"), (3, "caret")):
        frames, times, keys = _synthetic(20, late, cursor=cursor)
        keep = [0] + [j for j in range(1, len(frames)) if (frames[j] != frames[j - 1]).any()]
        out = judge(frames[keep], [times[j] for j in keep], keys)
        assert "keys" in out and all(g == late for g in refr(out)), (late, cursor, out.get("error"), refr(out) if "keys" in out else None)
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
