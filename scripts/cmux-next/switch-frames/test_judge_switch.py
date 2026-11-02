#!/usr/bin/env python3
"""Self-test of judge_switch.py on a synthetic H.264 video with one known defect per switch.

Run: python3 test_judge_switch.py [--keep DIR]   (needs numpy and PyAV; no app, no Mac)
Each switch injects exactly one defect class (or none); the judge must report exactly that class.
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "journeys"))
import ext_switch as bc  # noqa: E402  (the beacon codec)
import judge_switch as js  # noqa: E402

W, H, HZ = 1280, 800, 120
BW, BH = 16, 24
SIDEBAR = 240
PANES = [(260, 40, 500, 750), (770, 40, 500, 750)]  # x, y, w, h
BG = np.array([30, 30, 30], np.uint8)
LATENCY_MS = 12.0

# (from, to, defect, photon refreshes)
SWITCHES = [
    (1, 2, None, 1),
    (2, 3, "sidebar-late", 1),
    (3, 4, "half-drawn", 1),
    (4, 1, "blank", 1),
    (1, 2, "stale", 1),
    (2, 3, "old-after-switch", 1),
    (3, 4, "slow", 4),
]
GAP = 1.2  # s between switches
T0 = 0.6


PLAIN = "--plain" in sys.argv


def texture(ws, pane, w, h):
    rng = np.random.default_rng(ws * 100 + pane)
    cells = rng.integers(40, 220, size=(h // 16 + 1, w // 8 + 1, 3), dtype=np.uint8)
    # --plain: a real terminal: mostly background, a few short text lines at the top.
    cells[rng.random(cells.shape[:2]) < (0.5 if not PLAIN else 0.97)] = BG
    if PLAIN:
        cells[12:, :] = BG
    return np.repeat(np.repeat(cells, 16, axis=0), 8, axis=1)[:h, :w]


TEX = {(ws, p): texture(ws, p, PANES[p][2], PANES[p][3]) for ws in range(1, 5) for p in range(2)}


def draw_beacon(img, x, y, ws, pane, clock):
    for r, data in enumerate(bc.rows(ws, pane, clock)):
        cols = ["Y"] + data + ["R"]
        for i, c in enumerate(cols):
            img[y + r * BH: y + (r + 1) * BH, x + i * BW: x + (i + 1) * BW] = bc.COLORS[c]


def draw(t, sel, panes, clocks):
    """panes: [ws or None (blank)] per pane; clocks: beacon clock ms per pane."""
    img = np.empty((H, W, 3), np.uint8)
    img[:] = BG
    img[:, :SIDEBAR] = (24, 24, 28)
    for i in range(4):
        y = 100 + 60 * i
        img[y:y + 50, 10:SIDEBAR - 10] = (70, 100, 210) if sel == i + 1 else (40, 40, 46)
        img[y + 18:y + 32, 30:30 + 40 * (i + 1)] = (230, 230, 230)
    for p, ws in enumerate(panes):
        x, y, w, h = PANES[p]
        if ws is None:
            continue
        img[y:y + h, x:x + w] = TEX[(ws, p)]
        draw_beacon(img, x + 8, y + 8, ws, p, int(clocks[p] // bc.CLOCK_UNIT_MS) % (1 << bc.CLOCK_BITS))
        # a live band that changes every frame (a busy terminal row)
        band = int(t * HZ) % 40
        img[y + 200: y + 216, x + 8: x + w - 8] = (band * 5, 120, 255 - band * 5)
    return img


def build(path: Path):
    import av

    n = int((T0 + GAP * len(SWITCHES) + 0.3) * HZ)
    events = []
    plan = {}  # frame index -> (sel, panes, frozen)
    for i, (a, b, defect, photon) in enumerate(SWITCHES):
        tk = T0 + GAP * i + 0.3 / HZ   # the key-down falls between two refreshes
        events.append({"t": tk, "case": f"ws{a}->ws{b}", "expect": defect})
        k = int(np.ceil(tk * HZ))  # the first refresh at or after the key
        f1 = k + photon - 1          # photon frame index
        for j in range(k, f1):
            plan[j] = (a, [a, a], None)
        if defect == "sidebar-late":
            plan[f1] = (a, [b, b], None)
        elif defect == "half-drawn":
            plan[f1] = (b, [b, a], None)
        elif defect == "blank":
            plan[f1] = (b, [b, None], None)
        elif defect == "stale":
            for j in range(f1, f1 + 3):
                plan[j] = (b, [b, b], {0: (T0 + GAP * (i - 1)) * 1000.0})  # pane 0 frozen at its hide time
        elif defect == "old-after-switch":
            plan[f1 + 1] = (a, [a, a], None)
        events[-1]["photon"] = photon
    with av.open(str(path), "w") as box:
        st = box.add_stream("libx264", rate=HZ)
        st.width, st.height, st.pix_fmt = W, H, "yuv420p"
        st.options = {"crf": "20", "preset": "veryfast"}
        cur = SWITCHES[0][0]
        si = 0
        for j in range(n):
            t = j / HZ
            while si < len(SWITCHES) and j >= int(np.ceil(events[si]["t"] * HZ)) + events[si]["photon"] - 1:
                cur = SWITCHES[si][1]
                si += 1
            sel, panes, frozen = plan.get(j, (cur, [cur, cur], None))
            clocks = [t * 1000.0 - LATENCY_MS] * 2
            if frozen:
                for p, c in frozen.items():
                    clocks[p] = c
            img = draw(t, sel, panes, clocks)
            fr = av.VideoFrame.from_ndarray(img, format="rgb24")
            fr.pts = j
            for pkt in st.encode(fr):
                box.mux(pkt)
        for pkt in st.encode():
            box.mux(pkt)
    return events


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep")
    ap.add_argument("--plain", action="store_true", help="mostly-empty panes (a real terminal) instead of full texture")
    args = ap.parse_args()
    d = Path(args.keep or tempfile.mkdtemp(prefix="judge-switch-"))
    d.mkdir(parents=True, exist_ok=True)
    video = d / "synthetic.mp4"
    events = build(video)
    (d / "events.json").write_text(json.dumps(events, indent=1))
    results = js.judge(str(video), [dict(e) for e in events], HZ, None)
    bad = 0
    for ev, r in zip(events, results):
        kinds = sorted({x["kind"] for x in r["defects"]})
        want = [] if ev["expect"] in (None, "slow") else [ev["expect"]]
        # A half-drawn or blank first frame is not the target's complete frame: the photon is the next one.
        want_photon = ev["photon"] + (1 if ev["expect"] in ("half-drawn", "blank") else 0)
        ok = kinds == want and r.get("photon_refreshes") == want_photon and r.get("first_change_refreshes") == ev["photon"]
        bad += not ok
        print(f"{'ok ' if ok else 'BAD'} {ev['case']:10} expect {ev['expect']!s:18} got {kinds} photon {r.get('photon_refreshes')} (want {want_photon}) verdict {r['verdict']}")
        if not ok:
            print("    ", json.dumps({k: r[k] for k in r if k not in ('timeline',)}, default=str)[:1500])
            print("    ", r.get("timeline")[:8])
    print(json.dumps(js.summary(results)))
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
