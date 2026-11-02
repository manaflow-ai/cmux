#!/usr/bin/env python3
"""TYPING UNDER LOAD video judge: display refreshes from each HID key to the first frame that shows its effect.

    judge_keys.py --video PART.mov --frames PART.mov.frames.json --result result.json --label PART [--out OUT.json]
    judge_keys.py self-test

Works for every key the typist plays (a character, Backspace, an arrow, Ctrl-C, Return, a paste): the crop is the
typing pane (typing_rect, window points x the recording's scale), and a key's frame is the first movie frame after
its post time that differs from the frame shown at the post time over at least 1.5 terminal cells of width (a
character adds a glyph AND moves the cursor: 2 cells, since a terminal shows the cursor solid on input; a cursor blink
alone is 1 cell and never counts). A key whose
effect is not shown before the next key's post is matched in the later frames up to 0.5 s (its count then says how
late it was). Refreshes = vsync instants in (t_post, frame t], 1 = the next refresh (120 Hz grid from the frame times).
Output: per key {i, kind, t_post, frame, video_s, refreshes}, the summary {n, shown, p50, p95, p99, max, over1,
over2}, and stalls: every key over 2 refreshes with its video time (the clip list for the gallery).
"""
import argparse
import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


def np():
    import numpy
    return numpy


def judge(frames, times, events, cell_px, refresh_hz=120.0, thresh=24):
    n = np()
    period = 1.0 / refresh_hz
    phase = float(n.median([t % period for t in times])) if times else 0.0
    rows, defects = [], []

    def shown_at(t):
        return max([i for i, tt in enumerate(times) if tt <= t] or [0])
    for k, e in enumerate(events):
        t0 = e["t_post"]
        base = frames[shown_at(t0)].astype(n.int16)
        limit = t0 + 0.5
        idx = None
        for j in range(shown_at(t0) + 1, len(times)):
            if times[j] > limit:
                break
            if times[j] <= t0:
                continue
            cols = n.nonzero((n.abs(frames[j].astype(n.int16) - base) > thresh).any(axis=0))[0]
            if cols.size and (cols[-1] - cols[0] + 1) >= 1.5 * cell_px:
                idx = j
                break
            # a change of 1.5 cells may also be in two rows (a wrap): count the columns that changed
            if cols.size >= 1.5 * cell_px:
                idx = j
                break
        if idx is None:
            rows.append(dict(i=e["i"], kind=e["kind"], t_post=t0, frame=None, refreshes=None))
            continue
        t = times[idx]
        first_vsync = math.floor((t0 - phase) / period) * period + phase + period
        refreshes = int(round((t - first_vsync) / period)) + 1
        rows.append(dict(i=e["i"], kind=e["kind"], t_post=t0, frame=idx, t_frame=round(t, 6),
                         video_s=round(t - times[0], 4), refreshes=refreshes))
        if refreshes > 2:
            defects.append({"kind": "stall", "key": e["i"], "key_kind": e["kind"], "frame": idx,
                            "video_s": round(t - times[0], 4), "refreshes": refreshes})
    got = sorted(r["refreshes"] for r in rows if r.get("refreshes") is not None)

    def pct(p):
        return got[min(len(got) - 1, int(math.ceil(p / 100.0 * len(got))) - 1)] if got else None
    summary = {"n": len(events), "shown": len(got), "missing": len(events) - len(got), "p50": pct(50), "p95": pct(95),
               "p99": pct(99), "max": got[-1] if got else None, "over1": sum(1 for g in got if g > 1),
               "over2": sum(1 for g in got if g > 2)}
    return {"keys": rows, "summary": summary, "stalls": defects}


def self_test():
    n = np()
    period = 1 / 120.0
    times = [i * period for i in range(300)]
    cell = 10
    events = [{"i": i, "kind": "char", "t_post": 0.1 + i * 0.1 + 0.001} for i in range(20)]
    late = {i: (5 if i == 7 else 1) for i in range(20)}
    frames = []
    for j, t in enumerate(times):
        f = n.zeros((20, 400), dtype=n.uint8)
        shown = [i for i, e in enumerate(events) if t >= (math.floor(e["t_post"] / period + 1e-9) + late[i]) * period - 1e-6]
        count = len(shown)
        f[4:16, 0: cell * count] = 200
        # A block cursor that blinks when idle and is solid for 0.6 s after each glyph (a terminal resets the blink on
        # input), as Ghostty's.
        last = max([(math.floor(events[i]["t_post"] / period + 1e-9) + late[i]) * period for i in shown] or [-9])
        on = (t - last) < 0.6 or (j // 60) % 2 == 0
        f[2:18, cell * count: cell * count + cell] = 120 if on else 0
        frames.append(f)
    out = judge(n.stack(frames), times, events, cell)
    got = [r["refreshes"] for r in out["keys"]]
    assert got[7] == 5 and all(g == 1 for i, g in enumerate(got) if i != 7), got
    assert out["summary"]["over2"] == 1 and out["stalls"][0]["key"] == 7, out["summary"]
    print("self-test OK", json.dumps(out["summary"]))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("cmd", nargs="?")
    ap.add_argument("--video"); ap.add_argument("--frames"); ap.add_argument("--result"); ap.add_argument("--label")
    ap.add_argument("--refresh-hz", type=float, default=120.0); ap.add_argument("--out")
    a = ap.parse_args()
    if a.cmd == "self-test":
        self_test()
        return 0
    import judge as line_judge  # decode_band and movie_times
    steps = json.loads(Path(a.result).read_text()).get("steps", [])
    play = next(s for s in steps if s.get("do") == "typist_play" and (s.get("result") or {}).get("label") == a.label)
    rect = next(s for s in steps if s.get("do") == "typing_rect" and s.get("ok"))["result"]
    meta = json.loads(Path(str(a.video)[:-4] + ".meta.json").read_text())
    scale = float(meta["start"]["scale"])
    crop = [int(round(v * scale)) for v in rect["rect_points_top_left"]]
    crop[2] -= crop[2] % 2
    crop[3] -= crop[3] % 2
    frames = line_judge.decode_band(a.video, crop)
    times = line_judge.movie_times(a.frames)
    m = min(len(frames), len(times))
    cell = float(rect.get("cell_width") or 8) * scale
    out = judge(frames[:m], times[:m], play["result"]["events"], cell, a.refresh_hz)
    out["input"] = {"video": a.video, "crop_px": crop, "scale": scale, "cell_px": cell, "refresh_ms": meta.get("refresh_ms")}
    if a.out:
        Path(a.out).write_text(json.dumps(out, indent=1))
    print(json.dumps(out["summary"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
