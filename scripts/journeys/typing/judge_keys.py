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


def judge(frames, times, events, cell_px, refresh_hz=120.0, thresh=24, cell_h_px=None, origin=None, start=(0, 0)):
    """A line-editor model of the typing pane (echo.py's echo, see its docstring) says, for each key, the one cell where
    the cursor lands after it: a character or a space at (row, col + 1); Backspace and Left at (row, col - 1); Right
    at (row, col + 1); Return and Ctrl-C at (row + 1, 0); a paste of L characters at (row, col + L). The key is shown
    in the first movie frame after its start in which that cell differs from the frame shown at the start (at least
    6 pixels over THRESH): before the key the cursor is not in that cell, so a cursor blink cannot change it, and a
    late echo of the key before or a relayout elsewhere in the pane never counts. ORIGIN (x, y) of cell (0, 0) in the
    crop: from the first key's change when not given. Rows scroll at the pane's last row. A key not shown within
    0.5 s is `missing`. START (row, col) is the cursor cell before the first key (a later part of the same run passes
    the end state and origin of the part before; summary `end` and `origin`)."""
    n = np()
    period = 1.0 / refresh_hz
    cell_h = float(cell_h_px or 2 * cell_px)
    phase = float(n.median([t % period for t in times])) if times else 0.0
    height, width = frames.shape[1], frames.shape[2]
    rows_visible = None  # set once the origin is known: (height - origin_y) // cell_h (review should-fix 1)

    def shown_at(t):
        return max([i for i, tt in enumerate(times) if tt <= t] or [0])

    def cell_box(row, col):
        x0 = int(round(origin[0] + col * cell_px))
        y0 = int(round(origin[1] + row * cell_h))
        return y0, min(height, int(round(y0 + cell_h))), x0, min(width, int(round(x0 + cell_px)))

    if origin is None and events:
        e = events[0]
        t0 = e.get("t_start", e["t_post"])
        b = shown_at(t0)
        for j in range(b + 1, len(times)):
            if times[j] > t0 + 0.5:
                break
            m = n.abs(frames[j].astype(n.int16) - frames[b].astype(n.int16)) > thresh
            if m.any():
                rr, cc = n.nonzero(m.any(axis=1))[0], n.nonzero(m.any(axis=0))[0]
                origin = (float(cc[0]), float(rr[0]))
                break
    if origin is None:
        return {"error": "the first key changed nothing in the pane", "keys": [], "summary": {}, "stalls": []}
    rows_visible = max(1, int((height - origin[1]) // cell_h))
    row, col = start
    rows, defects = [], []
    for e in events:
        kind = e["kind"]
        if kind in ("char",):
            nrow, ncol = row, col + 1
        elif kind == "paste":
            nrow, ncol = row, col + len(e.get("text") or "")
        elif kind in ("backspace", "left"):
            nrow, ncol = row, max(0, col - 1)
        elif kind == "right":
            nrow, ncol = row, col + 1
        else:  # return, ctrl_c
            nrow, ncol = min(row + 1, rows_visible - 1), 0
        scrolled = kind in ("return", "ctrl_c") and row + 1 >= rows_visible
        t0 = e.get("t_start", e["t_post"])
        b = shown_at(t0)
        y0, y1, x0, x1 = cell_box(nrow, ncol)
        base = frames[b, y0:y1, x0:x1].astype(n.int16)
        idx = None
        for j in range(b + 1, len(times)):
            if times[j] > t0 + 0.5:
                break
            if times[j] <= t0:
                continue
            if int((n.abs(frames[j, y0:y1, x0:x1].astype(n.int16) - base) > thresh).sum()) >= 6:
                idx = j
                break
        row, col = nrow, ncol
        if idx is None:
            rows.append(dict(i=e["i"], kind=kind, t_start=t0, frame=None, refreshes=None, cell=[nrow, ncol],
                             scrolled=scrolled))
            defects.append({"kind": "missing", "key": e["i"], "key_kind": kind, "cell": [nrow, ncol]})
            continue
        t = times[idx]
        first_vsync = math.floor((t0 - phase) / period) * period + phase + period
        refreshes = int(round((t - first_vsync) / period)) + 1
        rows.append(dict(i=e["i"], kind=kind, t_start=t0, frame=idx, t_frame=round(t, 6), video_s=round(t - times[0], 4),
                         refreshes=refreshes, cell=[nrow, ncol]))
        if refreshes > 2:
            defects.append({"kind": "stall", "key": e["i"], "key_kind": kind, "frame": idx,
                            "video_s": round(t - times[0], 4), "refreshes": refreshes})
    got = sorted(r["refreshes"] for r in rows if r.get("refreshes") is not None)
    allk = sorted(got + [10 ** 6] * (len(events) - len(got)))  # a missing key is the worst key

    def pct(p):
        return allk[min(len(allk) - 1, int(math.ceil(p / 100.0 * len(allk))) - 1)] if allk else None
    summary = {"n": len(events), "shown": len(got), "missing": len(events) - len(got), "p50": pct(50), "p95": pct(95),
               "p99": pct(99), "max": allk[-1] if allk else None, "over1": sum(1 for g in allk if g > 1),
               "over2": sum(1 for g in allk if g > 2), "origin": [round(origin[0], 3), round(origin[1], 3)],
               "end": [row, col]}
    return {"keys": rows, "summary": summary, "stalls": defects}


def _synthetic(kinds, late, cell=8, cell_h=17, blink=True, period=1 / 120.0, gap=0.1, toast=None):
    """A pane at 1x: origin (4, 4); each event of KINDS ("c" char, "b" backspace, "r" return) changes the screen at the
    LATE[i]-th refresh after its post; a block cursor that blinks every 0.5 s while idle (solid 0.6 s after input)."""
    n = np()
    events = [{"i": i, "kind": {"c": "char", "b": "backspace", "r": "return"}[k], "key": "x", "t_post": 0.1 + i * gap + 0.001}
              for i, k in enumerate(kinds)]
    shows = [(math.floor(e["t_post"] / period + 1e-9) + late[i]) * period - 1e-6 for i, e in enumerate(events)]
    times = [i * period for i in range(int((len(kinds) * gap + 1.0) / period))]
    frames = []
    for j, t in enumerate(times):
        f = n.zeros((200, 400), dtype=n.uint8)
        row, col, text = 0, 0, {}
        last = -9
        for i, e in enumerate(events):
            if shows[i] > t:
                continue
            last = max(last, shows[i])
            if e["kind"] == "char":
                text[(row, col)] = 1
                col += 1
            elif e["kind"] == "backspace":
                col = max(0, col - 1)
                text.pop((row, col), None)
            else:
                row, col = row + 1, 0
        for (r, c) in text:
            f[4 + r * cell_h + 3: 4 + r * cell_h + 14, 4 + c * cell + 1: 4 + c * cell + 7] = 200
        on = (t - last) < 0.6 or not blink or int(t / 0.5) % 2 == 0
        if on:
            f[4 + row * cell_h: 4 + (row + 1) * cell_h, 4 + col * cell: 4 + (col + 1) * cell] = 120
        if toast is not None and toast[0] <= j < toast[1]:
            f[150:170, 300:390] = 255
        frames.append(f)
    return n.stack(frames), times, events


def self_test():
    def refr(out):
        return [r["refreshes"] for r in out["keys"]]
    kinds = "cccccbcccrcccc"
    late = [1] * len(kinds)
    late[6] = 5
    frames, times, events = _synthetic(kinds, late)
    out = judge(frames, times, events, 8, cell_h_px=17)
    got = refr(out)
    assert got[6] == 5 and all(g == 1 for i, g in enumerate(got) if i != 6), got
    assert out["summary"]["over2"] == 1, out["summary"]
    # every key 3 refreshes late, with a toast elsewhere in the pane during the run: every key reads 3
    frames, times, events = _synthetic(kinds, [3] * len(kinds), toast=(40, 80))
    got = refr(judge(frames, times, events, 8, cell_h_px=17))
    assert all(g == 3 for g in got), got
    # a key whose effect never shows is missing and the worst key
    frames, times, events = _synthetic("cccc", [1, 1, 1, 10 ** 4])
    out = judge(frames, times, events, 8, cell_h_px=17)
    assert out["summary"]["missing"] == 1 and out["summary"]["max"] > 100, out["summary"]
    # only changed frames in the movie (the recorder drops idle refreshes): the same counts
    frames, times, events = _synthetic(kinds, late)
    keep = [0] + [j for j in range(1, len(frames)) if (frames[j] != frames[j - 1]).any()]
    got = refr(judge(frames[keep], [times[j] for j in keep], events, 8, cell_h_px=17))
    assert got[6] == 5 and all(g == 1 for i, g in enumerate(got) if i != 6), got
    print("self-test OK")


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
