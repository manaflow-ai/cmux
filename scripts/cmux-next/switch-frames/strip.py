#!/usr/bin/env python3
"""Frame strips for a judged switch: the frames around each switch (and each defect) side by side, one PNG each, so a
person checks the judge by eye and the gallery shows the evidence.

Usage: strip.py --judge JUDGE.json [--video V.mov --frames V.mov.frames.json] --out DIR [--before 2 --after 6]
         [--scale 0.25] [--only-defects]
Each PNG: one column per movie frame from `before` frames before the key-down to `after` frames after it; above each
frame its time from the key-down in ms and the judge's label (content / sidebar). Needs numpy and PyAV.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import judge_switch as js  # noqa: E402

# 3x5 digits and a few letters for labels (no font files on the VM).
GLYPHS = {
    "0": "111101101101111", "1": "010110010010111", "2": "111001111100111", "3": "111001111001111",
    "4": "101101111001001", "5": "111100111001111", "6": "111100111101111", "7": "111001010010010",
    "8": "111101111101111", "9": "111101111001111", "-": "000000111000000", "+": "000010111010000",
    ".": "000000000000010", " ": "000000000000000", "m": "000111111101101", "s": "011100010001110",
    "O": "111101101101111", "L": "100100100100111", "D": "110101101101110", "T": "111010010010010",
    "A": "010101111101101", "R": "110101110101101", "G": "111100101101111", "E": "111100111100111",
    "M": "101111111101101", "I": "111010010010111", "X": "101101010101101", "B": "110101110101110",
    "N": "101111111111101", "K": "101101110101101", "H": "101101111101101", "Z": "111001010100111",
    "/": "001001010100100", ":": "000010000010000", "P": "111101111100100", "S": "111100111001111",
    "W": "101101101111101", "C": "111100100100111", "F": "111100111100100", "U": "101101101101111",
    "Y": "101101010010010", "V": "101101101101010",
}


def text(img: np.ndarray, x: int, y: int, s: str, color=(255, 255, 255), k: int = 3):
    for ch in s.upper():
        g = GLYPHS.get(ch, GLYPHS[" "])
        for i, bit in enumerate(g):
            if bit == "1":
                r, c = divmod(i, 3)
                img[y + r * k: y + (r + 1) * k, x + c * k: x + (c + 1) * k] = color
        x += 4 * k


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--judge", required=True)
    ap.add_argument("--video")
    ap.add_argument("--frames")
    ap.add_argument("--out", required=True)
    ap.add_argument("--before", type=int, default=2)
    ap.add_argument("--after", type=int, default=6)
    ap.add_argument("--scale", type=float, default=0.25)
    ap.add_argument("--only-defects", action="store_true")
    a = ap.parse_args()
    import av

    j = json.load(open(a.judge))
    video = a.video or j["video"]
    frames_json = a.frames or (video + ".frames.json" if Path(video + ".frames.json").exists() else None)
    times = js.movie_times(frames_json) if frames_json else None
    hz = float(j.get("hz", 120))
    events = [e for e in j["events"] if not a.only_defects or e.get("defects")]
    windows = [(e["t"] - (a.before + 0.5) / hz, e["t"] + (a.after + 0.5) / hz) for e in events]
    order = sorted(range(len(events)), key=lambda i: windows[i][0])
    got: dict[int, list] = {i: [] for i in range(len(events))}
    wins = [windows[i] for i in order]
    for t, rgb in js.read_video(video, wins, times):
        for i in order:
            if windows[i][0] <= t <= windows[i][1]:
                got[i].append((t, rgb))
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    step = max(1, int(round(1 / a.scale)))
    for i, e in enumerate(events):
        cells = []
        labels = {round(x["t"], 4): x for x in e.get("timeline", [])}
        for t, rgb in got[i]:
            small = rgb[::step, ::step]
            head = np.zeros((40, small.shape[1], 3), np.uint8)
            ms = (t - e["t"]) * 1000
            text(head, 4, 4, f"{ms:+.1f}MS")
            lab = labels.get(round(t, 4))
            if lab:
                bad = lab["content"] != "TARGET" and ms > 0
                text(head, 4, 22, f"{lab['content'][:6]} {lab['sidebar'][:6]}", (255, 80, 80) if bad else (120, 255, 120))
            cells.append(np.concatenate([head, small], axis=0))
            cells.append(np.full((small.shape[0] + 40, 4, 3), 90, np.uint8))
        if not cells:
            continue
        sheet = np.concatenate(cells[:-1], axis=1)
        name = f"{i:02d}-{(e.get('case') or 'switch').replace('/', '_')}-{e['verdict']}.png"
        frame = av.VideoFrame.from_ndarray(np.ascontiguousarray(sheet), format="rgb24")
        with av.open(str(out / name), "w", format="image2") as box:
            st = box.add_stream("png", rate=1)
            st.width, st.height, st.pix_fmt = sheet.shape[1], sheet.shape[0], "rgb24"
            for pkt in st.encode(frame):
                box.mux(pkt)
            for pkt in st.encode():
                box.mux(pkt)
        print(out / name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
