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


def judge(frames, times, events, cell_px, refresh_hz=120.0, thresh=24, cell_h_px=None):
    """Each event's `t_start` (else `t_post`) is its key's start. A key's frame is the first movie frame after the
    start, and at or after the previous key's frame, that differs from the frame shown at that point over >= 1.5 cells
    of width, inside the typed line's band: the rows of the previous key's change +- one cell height (after a Return or
    Ctrl-C, the next line too). So a late echo of the key before, a relayout elsewhere in the pane or a toast never
    counts for this key (review should-fix 4 at 8802cbd6e87). A key not shown within 0.5 s is `missing` (the ledger
    counts it as a breach)."""
    n = np()
    period = 1.0 / refresh_hz
    phase = float(n.median([t % period for t in times])) if times else 0.0
    rows, defects = [], []
    cell_h = cell_h_px or 2 * cell_px
    band = None  # (r0, r1) of the line being typed
    prev_frame = 0

    def shown_at(t):
        return max([i for i, tt in enumerate(times) if tt <= t] or [0])
    for e in events:
        t0 = e.get("t_start", e["t_post"])
        b = max(shown_at(t0), prev_frame)
        base = frames[b].astype(n.int16)
        idx = None
        for j in range(b + 1, len(times)):
            if times[j] > t0 + 0.5:
                break
            if times[j] <= t0:
                continue
            m = n.abs(frames[j].astype(n.int16) - base) > thresh
            if band is not None:
                lo = max(0, int(band[0] - cell_h))
                hi = int(band[1] + cell_h * (2 if e["kind"] in ("return", "ctrl_c") else 1))
                m[:lo, :] = False
                m[hi:, :] = False
            cols = n.nonzero(m.any(axis=0))[0]
            if cols.size and (cols[-1] - cols[0] + 1) >= 1.5 * cell_px:
                r = n.nonzero(m.any(axis=1))[0]
                band = (int(r[0]), int(r[-1]) + 1) if e["kind"] not in ("return", "ctrl_c") else (int(r[-1]) + 1 - int(cell_h), int(r[-1]) + 1)
                idx = j
                break
        if idx is None:
            rows.append(dict(i=e["i"], kind=e["kind"], t_start=t0, frame=None, refreshes=None))
            defects.append({"kind": "missing", "key": e["i"], "key_kind": e["kind"]})
            continue
        prev_frame = idx
        t = times[idx]
        first_vsync = math.floor((t0 - phase) / period) * period + phase + period
        refreshes = int(round((t - first_vsync) / period)) + 1
        rows.append(dict(i=e["i"], kind=e["kind"], t_start=t0, frame=idx, t_frame=round(t, 6),
                         video_s=round(t - times[0], 4), refreshes=refreshes))
        if refreshes > 2:
            defects.append({"kind": "stall", "key": e["i"], "key_kind": e["kind"], "frame": idx,
                            "video_s": round(t - times[0], 4), "refreshes": refreshes})
    got = sorted(r["refreshes"] for r in rows if r.get("refreshes") is not None)
    # A missing key counts as worse than any measured one in the percentiles (review must-fix 1 at 8802cbd6e87).
    allk = got + [10 ** 6] * (len(events) - len(got))
    allk.sort()

    def pct(p):
        return allk[min(len(allk) - 1, int(math.ceil(p / 100.0 * len(allk))) - 1)] if allk else None
    summary = {"n": len(events), "shown": len(got), "missing": len(events) - len(got), "p50": pct(50), "p95": pct(95),
               "p99": pct(99), "max": allk[-1] if allk else None, "over1": sum(1 for g in allk if g > 1),
               "over2": sum(1 for g in allk if g > 2)}
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
    # A key that never shows is missing and counts as the worst key (max is no longer the measured 5).
    frames2 = n.stack(frames)
    ev2 = events + [{"i": 20, "kind": "char", "t_post": 2.2}]
    out2 = judge(frames2, times, ev2, cell)
    assert out2["summary"]["missing"] == 1 and out2["summary"]["max"] > 100, out2["summary"]
    # A change far from the typed line (a toast in rows 0-1 is outside the band once the band is known) does not count.
    f3 = frames2.copy()
    j_late = next(j for j, t in enumerate(times) if t > events[7]["t_post"])
    f3[j_late:j_late + 3, 0:1, :] = 255  # row 0: above the band (rows 2-18) by more than one cell height (1 here)
    out3 = judge(f3, times, events, cell, cell_h_px=1)
    assert [r["refreshes"] for r in out3["keys"]][7] == 5, out3["keys"][7]
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
