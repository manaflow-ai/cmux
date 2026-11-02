#!/usr/bin/env python3
"""Switch judge: is a workspace / tab / screen switch frame perfect in a screen video?

SWITCH FRAMES rule (Lawrence 2026-11-02, via the cmux-next Performance Lead):
  - the target's COMPLETE frame in the next display refresh after the input;
  - never a frame of the old content after the switch frame;
  - never blank or half-drawn;
  - terminals show their current content, not a stale snapshot that updates later;
  - the sidebar selection moves in the same frame as the content.

Input: a screen video (the RESIZE VIDEOS kit's capture, display rate) and the input events in the video's clock.
The judge needs no app geometry: it compares every frame after the input with two references made from the video
itself, the settled OLD state (just before the input) and the settled TARGET state (after the switch settled):
  - tiles (TILE x TILE video pixels after a DOWN x DOWN area average) label each frame OLD / TARGET / MIXED /
    BLANK / OTHER, separately for the sidebar (x < sidebar edge) and the content;
  - tiles whose pixels move in a settled state (a busy TUI, a CSS animation) carry no vote; beacons
    (scripts/journeys/ext_switch.py beacon: a color barcode of workspace id, pane id and a clock) still say which workspace such a pane shows
    and how old its frame is.

Usage:
  judge_switch.py --video V.mov --events E.json [--out R.json] [--hz 120] [--sidebar-right PX]
E.json: [{"t": seconds in video time (the HID key-down or mouse-down), "case": "cmd-2", "label": "..."}, ...]
        With --frames PATH.frames.json (the HARNESS recorder), "t" is in host seconds (CACurrentMediaTime).
        (or {"events": [...]}). Optional per event: "settle_start"/"settle_end" (s after t, default 0.6 / 0.9),
        "pre" (s of OLD reference before t, default 0.25), "window" (s judged after t, default settle_start).
Exit 0 always when it judged; the verdict per event is in the output ("pass": true/false, "defects": [...]).
Self-test: test_judge_switch.py makes synthetic videos with each defect and checks the judge finds exactly it.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "journeys"))
import ext_switch as bc  # noqa: E402  (the beacon codec: scripts/journeys/ext_switch.py)

DOWN = 4          # area-average factor for tile features
TILE = 8          # tile side in downscaled pixels (32 video pixels at DOWN 4)
MOVING = 18.0     # a tile whose settled frames differ by more than this (mean abs, 0-255) carries no vote
DISCRIM = 10.0    # a tile votes when OLD and TARGET references differ by more than this plus their noise
SLACK = 5.0       # a frame tile matches a reference within its noise plus this
BLANK_STD = 2.0   # a tile is blank when its pixels are this uniform while the reference tile has structure
STALE_REFRESHES = 2.0  # a beacon older than this many refreshes past the live latency is stale


# ---------- frames ----------

def downscale(rgb: np.ndarray, f: int = DOWN) -> np.ndarray:
    h, w, _ = rgb.shape
    h2, w2 = h // f * f, w // f * f
    x = rgb[:h2, :w2].reshape(h2 // f, f, w2 // f, f, 3).astype(np.float32)
    return x.mean(axis=(1, 3))


def tiles(small: np.ndarray) -> np.ndarray:
    """(ty, tx, TILE*TILE*3) tile vectors."""
    h, w, _ = small.shape
    th, tw = h // TILE, w // TILE
    x = small[: th * TILE, : tw * TILE].reshape(th, TILE, tw, TILE, 3)
    return x.transpose(0, 2, 1, 3, 4).reshape(th, tw, TILE * TILE * 3)


def movie_times(frames_json: str) -> list[float]:
    """Host display times of the movie's frames, in movie order, from the HARNESS recorder's PATH.frames.json
    (`debug.motion record_*`: every ScreenCaptureKit frame as [t host seconds, status, in movie])."""
    data = json.load(open(frames_json))
    rows = data.get("frames", data) if isinstance(data, dict) else data
    return [float(r[0]) for r in rows if (len(r) < 3 or r[2]) and (len(r) < 2 or r[1] != "idle")]


def read_video(path: str, windows: list[tuple[float, float]], times: list[float] | None = None):
    """Yield (t, full_rgb) for frames whose time falls in any window (sorted, non-overlapping). With `times`
    (movie_times), t is the frame's host display time instead of the movie's own time stamp."""
    import av

    with av.open(path) as box:
        stream = box.streams.video[0]
        stream.thread_type = "AUTO"
        wi = 0
        for i, frame in enumerate(box.decode(stream)):
            if times is not None and i >= len(times):
                break
            t = times[i] if times is not None else float(frame.time)
            while wi < len(windows) and t > windows[wi][1]:
                wi += 1
            if wi >= len(windows):
                break
            if t >= windows[wi][0]:
                yield t, frame.to_ndarray(format="rgb24")


# ---------- beacons ----------

PALETTE = {k: np.array(v, np.float32) for k, v in bc.COLORS.items()}


def classify_color(px: np.ndarray):
    best, dist = None, 1e9
    for k, v in PALETTE.items():
        d = float(np.linalg.norm(px - v))
        if d < dist:
            best, dist = k, d
    return best if dist < 110 else None


def sample(rgb: np.ndarray, x: float, y: float) -> np.ndarray:
    h, w, _ = rgb.shape
    xi, yi = int(round(x)), int(round(y))
    if not (1 <= xi < w - 1 and 1 <= yi < h - 1):
        return np.array([-999, -999, -999], np.float32)
    return rgb[yi - 1: yi + 2, xi - 1: xi + 2].reshape(-1, 3).astype(np.float32).mean(axis=0)


@dataclass
class BeaconSite:
    x: float      # center of the row-0 yellow block
    y: float
    bw: float     # block size
    bh: float


@dataclass
class BeaconRead:
    ws: int | None
    pane: int | None
    clock: int | None   # beacon clock units, or None when unreadable


def find_beacons(rgb: np.ndarray) -> list[BeaconSite]:
    """Every beacon on screen: three yellow blocks stacked one block apart."""
    r, g, b = rgb[..., 0].astype(np.int16), rgb[..., 1].astype(np.int16), rgb[..., 2].astype(np.int16)
    mask = (r > 190) & (g > 190) & (b < 110)
    ys = np.nonzero(mask.any(axis=1))[0]
    comps: list[list[int]] = []   # [x0, x1, y0, y1]
    open_runs: list[list[int]] = []
    prev_y = None
    for y in ys:
        row = mask[y]
        d = np.diff(np.concatenate([[0], row.view(np.int8), [0]]))
        starts, ends = np.nonzero(d == 1)[0], np.nonzero(d == -1)[0]
        new_open = []
        for s, e in zip(starts, ends):
            if e - s < 4:
                continue
            hit = None
            if prev_y is not None and y == prev_y + 1:
                for c in open_runs:
                    if s <= c[1] and e >= c[0]:
                        hit = c
                        break
            if hit is None:
                hit = [s, e, y, y]
                comps.append(hit)
            else:
                hit[0], hit[1], hit[3] = min(hit[0], s), max(hit[1], e), y
            new_open.append(hit)
        open_runs, prev_y = new_open, y
    # The three rows' yellow start blocks touch: one beacon is one yellow column three blocks tall. Its block
    # height is a third of it; a candidate is kept only when its rows decode (parity and end blocks).
    sites = []
    for x0, x1, y0, y1 in comps:
        w, h = x1 - x0, y1 - y0 + 1
        if w >= 5 and h >= 15 and mask[y0: y1 + 1, x0:x1].mean() > 0.8:
            bh = h / 3.0
            s = BeaconSite(x0 + w / 2, y0 + bh / 2, float(w), bh)
            r = read_beacon(rgb, s)
            if r is not None and r.ws is not None:
                sites.append(s)
    return sites


def read_row(rgb, x, y, bw, n):
    if classify_color(sample(rgb, x, y)) != "Y":
        return None
    out = []
    for k in range(1, n + 1):
        c = classify_color(sample(rgb, x + k * bw, y))
        if c not in (0, 1):
            return None
        out.append(c)
    if classify_color(sample(rgb, x + (n + 1) * bw, y)) != "R":
        return None
    if bc.parity(out[:-1]) != out[-1]:
        return None
    return out[:-1]


def read_beacon(rgb: np.ndarray, s: BeaconSite) -> BeaconRead | None:
    """None when no beacon is at the site; a read with None fields when it is there but unreadable."""
    if classify_color(sample(rgb, s.x, s.y)) != "Y":
        return None
    ids = read_row(rgb, s.x, s.y, s.bw, bc.WS_BITS + bc.PANE_BITS + 1)
    hi = read_row(rgb, s.x, s.y + s.bh, s.bw, 10)
    lo = read_row(rgb, s.x, s.y + 2 * s.bh, s.bw, 10)
    if ids is None:
        return BeaconRead(None, None, None)
    ws = int("".join(map(str, ids[: bc.WS_BITS])), 2)
    pane = int("".join(map(str, ids[bc.WS_BITS:])), 2)
    clock = None
    if hi is not None and lo is not None:
        clock = bc.ungray(int("".join(map(str, hi + lo)), 2))
    return BeaconRead(ws, pane, clock)


def clock_diff_ms(a: int, b: int) -> float:
    """a - b in ms, modulo the beacon clock."""
    m = 1 << bc.CLOCK_BITS
    d = (a - b) % m
    if d > m // 2:
        d -= m
    return d * bc.CLOCK_UNIT_MS


# ---------- states ----------

@dataclass
class State:
    ref: np.ndarray        # (ty, tx, n) median tile vectors
    noise: np.ndarray      # (ty, tx) max mean-abs diff of settled frames to the median
    struct: np.ndarray     # (ty, tx) pixel std of the reference tile
    beacons: dict = field(default_factory=dict)  # (ws, pane) -> BeaconSite
    ws: set = field(default_factory=set)


def make_state(tile_stack: list[np.ndarray], last_full: np.ndarray) -> State:
    st = np.stack(tile_stack)
    ref = np.median(st, axis=0)
    noise = np.abs(st - ref).mean(axis=3).max(axis=0)
    struct = ref.reshape(*ref.shape[:2], -1, 3).std(axis=2).mean(axis=2)
    beacons = {}
    for s in find_beacons(last_full):
        r = read_beacon(last_full, s)
        if r and r.ws is not None:
            beacons[(r.ws, r.pane)] = s
    return State(ref, noise, struct, beacons, {k[0] for k in beacons})


# ---------- judging ----------

@dataclass
class Frame:
    t: float
    label: str
    side: str
    content_old: float
    content_tgt: float
    content_blank: float
    old_bbox: list | None
    beacons: dict


def label_region(fr, old: State, tgt: State, vote: np.ndarray):
    d_old = np.abs(fr - old.ref).mean(axis=2)
    d_tgt = np.abs(fr - tgt.ref).mean(axis=2)
    # Scale-free match: a voting tile differs between OLD and TARGET by d_ot; a frame tile matches a reference
    # when it is within a third of that distance (plus the reference's own noise). Lossy video (a scene-change
    # frame is coded coarser than a settled one) stays far inside that margin.
    d_ot = np.abs(old.ref - tgt.ref).mean(axis=2)
    m_old = d_old <= np.maximum(old.noise + SLACK, d_ot / 3.0)
    m_tgt = d_tgt <= np.maximum(tgt.noise + SLACK, d_ot / 3.0)
    std = fr.reshape(*fr.shape[:2], -1, 3).std(axis=2).mean(axis=2)
    blank = (~m_tgt) & (~m_old) & (std < BLANK_STD) & (tgt.struct > 4 * BLANK_STD)
    n = max(int(vote.sum()), 1)
    only_old = vote & m_old & ~m_tgt
    only_tgt = vote & m_tgt & ~m_old
    neither = vote & ~m_old & ~m_tgt
    f_old, f_tgt, f_nei = only_old.sum() / n, only_tgt.sum() / n, neither.sum() / n
    f_blank = (vote & blank).sum() / n
    if vote.sum() == 0:
        lab = "NONE"
    elif f_tgt < 0.02 and f_old > 0.9:
        lab = "OLD"
    elif f_old < 0.02 and f_tgt > 0.95:
        lab = "TARGET"
    elif f_old >= 0.02 and f_tgt >= 0.02:
        lab = "MIXED"
    elif f_blank > 0.05:
        lab = "BLANK"
    elif f_old > 0.9:
        lab = "OLD"
    else:
        lab = "OTHER"
    bbox = None
    if lab in ("MIXED", "OTHER", "BLANK"):
        bad = only_old | neither
        if bad.any():
            ys, xs = np.nonzero(bad)
            k = TILE * DOWN
            bbox = [int(xs.min() * k), int(ys.min() * k), int((xs.max() + 1) * k), int((ys.max() + 1) * k)]
    return lab, float(f_old), float(f_tgt), float(f_blank), bbox


def judge_event(ev: dict, frames: list[tuple[float, np.ndarray, np.ndarray]], hz: float, sidebar_right: int | None):
    """frames: (t, tiles, full_rgb or None) in the event's whole window, sorted by t."""
    t0 = float(ev["t"])
    pre = float(ev.get("pre", 0.25))
    s0, s1 = float(ev.get("settle_start", 0.6)), float(ev.get("settle_end", 0.9))
    win = float(ev.get("window", s0))
    period = 1.0 / hz
    before = [f for f in frames if t0 - pre <= f[0] < t0]
    after_settle = [f for f in frames if t0 + s0 <= f[0] <= t0 + s1]
    judged = [f for f in frames if t0 <= f[0] < t0 + win]
    res = {"case": ev.get("case"), "label": ev.get("label"), "t": t0, "pass": False, "defects": []}
    if len(before) < 3 or len(after_settle) < 3:
        res["verdict"] = "NOVERDICT"
        res["reason"] = f"too few settled frames (old {len(before)}, target {len(after_settle)})"
        return res
    last_full_old = next((f[2] for f in reversed(before) if f[2] is not None), None)
    last_full_tgt = next((f[2] for f in reversed(after_settle) if f[2] is not None), None)
    old = make_state([f[1] for f in before], last_full_old)
    tgt = make_state([f[1] for f in after_settle], last_full_tgt)
    ty, tx = old.ref.shape[:2]
    k = TILE * DOWN
    if sidebar_right is None:
        xs = [s.x - s.bw for s in list(old.beacons.values()) + list(tgt.beacons.values())]
        sidebar_right = int(min(xs)) - k if xs else 0
    side_cols = np.zeros((ty, tx), bool)
    side_cols[:, : max(0, sidebar_right // k)] = True
    base_vote = (np.abs(old.ref - tgt.ref).mean(axis=2) > DISCRIM + np.maximum(old.noise, tgt.noise)) \
        & (old.noise < MOVING) & (tgt.noise < MOVING)
    vote_side, vote_content = base_vote & side_cols, base_vote & ~side_cols
    res["old_ws"], res["target_ws"] = sorted(old.ws), sorted(tgt.ws)
    res["votes"] = {"sidebar": int(vote_side.sum()), "content": int(vote_content.sum())}
    res["sidebar_right_px"] = sidebar_right

    # Live beacon latency before the input: offset between video time and beacon clock.
    sites = {**{("old",) + k2: v for k2, v in old.beacons.items()}, **{("tgt",) + k2: v for k2, v in tgt.beacons.items()}}
    offs = []
    for t, _, full in before:
        if full is None:
            continue
        for key, s in old.beacons.items():
            r = read_beacon(full, s)
            if r and r.clock is not None and r.ws == key[0]:
                offs.append(r.clock * bc.CLOCK_UNIT_MS - t * 1000.0)
    live_off = None
    if offs:  # the clock wraps: take every offset relative to the first, modulo the clock, then the median
        m = (1 << bc.CLOCK_BITS) * bc.CLOCK_UNIT_MS
        rel = [((o - offs[0] + m / 2) % m) - m / 2 for o in offs]
        live_off = offs[0] + float(np.median(rel))
    # reference the offset modulo the clock: store the clock of t=0
    out_frames: list[Frame] = []
    for t, tl, full in judged:
        lab_c, fo, ft, fb, bbox = label_region(tl, old, tgt, vote_content)
        lab_s = label_region(tl, old, tgt, vote_side)[0]
        reads = {}
        if full is not None:
            for key, s in sites.items():
                r = read_beacon(full, s)
                if r is None:
                    continue
                age = None
                if r.clock is not None and live_off is not None:
                    live_clock = int(round((t * 1000.0 + live_off) / bc.CLOCK_UNIT_MS)) % (1 << bc.CLOCK_BITS)
                    age = clock_diff_ms(live_clock, r.clock)
                reads[f"{key[0]}:{r.ws}:{r.pane}"] = {"ws": r.ws, "pane": r.pane, "age_ms": age}
        out_frames.append(Frame(t, lab_c, lab_s, fo, ft, fb, bbox, reads))

    # Beacons decide content when tiles cannot vote (busy panes): a beacon of an OLD-only workspace after the
    # first target frame is old content; a missing target beacon is half-drawn.
    def beacon_state(fr: Frame):
        seen = {(v["ws"], v["pane"]) for v in fr.beacons.values() if v["ws"] is not None}
        old_only = {kk for kk in old.beacons if kk[0] not in tgt.ws}
        has_old = bool(seen & old_only)
        has_all_tgt = set(tgt.beacons) <= seen
        return has_old, has_all_tgt

    def refreshes(t):
        return max(0, math.ceil((t - t0) / period - 1e-6))

    first_change = next((f for f in out_frames if f.label != "OLD" or f.side not in ("OLD", "NONE")), None)
    first_tgt = None
    for f in out_frames:
        has_old, has_all = beacon_state(f)
        if f.label in ("TARGET", "NONE") and not has_old and has_all and (f.label == "TARGET" or tgt.beacons):
            first_tgt = f
            break
    res["frames"] = len(out_frames)
    if first_change:
        res["first_change_t"] = first_change.t
        res["first_change_refreshes"] = refreshes(first_change.t)
    if first_tgt:
        res["photon_t"] = first_tgt.t
        res["photon_ms"] = round((first_tgt.t - t0) * 1000.0, 2)
        res["photon_refreshes"] = refreshes(first_tgt.t)

    defects = []

    def add(kind, fr, detail):
        if defects and defects[-1]["kind"] == kind and abs(defects[-1]["t_end"] - fr.t) < 1.6 * period + 1e-6:
            defects[-1]["t_end"] = fr.t
            defects[-1]["frames"] += 1
            return
        defects.append({"kind": kind, "t": round(fr.t, 4), "t_end": fr.t, "frames": 1, "detail": detail})

    if first_tgt is None:
        defects.append({"kind": "never-complete", "t": t0, "t_end": t0 + win, "frames": len(out_frames),
                        "detail": f"no complete target frame within {win:.2f} s"})
    started = False
    for f in out_frames:
        has_old, has_all = beacon_state(f)
        if f is first_change:
            started = True
        if not started:
            continue
        # Frames before the first complete target frame: anything but OLD there is a half-drawn or blank frame.
        if first_tgt is None or f.t < first_tgt.t:
            if f.label in ("MIXED", "OTHER", "BLANK") or (f.label == "TARGET" and not has_all) or (has_old and f.label == "TARGET"):
                add({"MIXED": "half-drawn", "BLANK": "blank", "OTHER": "half-drawn"}.get(f.label, "half-drawn"), f,
                    {"content": f.label, "old_tiles": round(f.content_old, 3), "target_tiles": round(f.content_tgt, 3),
                     "bbox": f.old_bbox, "beacons": f.beacons})
            if f.side == "TARGET" and f.label == "OLD":
                add("sidebar-early", f, {"sidebar": f.side, "content": f.label})
            continue
        # After the switch frame: never old content, never blank or half-drawn.
        if f.label == "OLD" or has_old:
            add("old-after-switch", f, {"content": f.label, "beacons": f.beacons})
        elif f.label in ("MIXED", "OTHER", "BLANK") or not has_all:
            add("blank" if f.label == "BLANK" else "half-drawn", f,
                {"content": f.label, "old_tiles": round(f.content_old, 3), "target_tiles": round(f.content_tgt, 3),
                 "bbox": f.old_bbox, "missing_beacons": sorted(map(list, set(tgt.beacons) - {(v['ws'], v['pane']) for v in f.beacons.values()}))})
        if f.side == "OLD" and vote_side.any() and f.label != "OLD" and not has_old:  # a whole old frame is one defect
            add("sidebar-late", f, {"sidebar": f.side, "content": f.label})
        for key, v in f.beacons.items():
            if key.startswith("tgt:") and v["age_ms"] is not None and v["age_ms"] > STALE_REFRESHES * period * 1000.0:
                add("stale", f, {"pane": key, "age_ms": round(v["age_ms"], 1),
                                 "age_refreshes": round(v["age_ms"] / (period * 1000.0), 1)})
    # Display refreshes with no new frame while the switch draws (a busy beacon redraws every refresh).
    ts = [f.t for f in out_frames]
    gaps = [b - a for a, b in zip(ts, ts[1:]) if b - a > 1.5 * period]
    res["dropped_refreshes"] = int(sum(round(g / period) - 1 for g in gaps))
    if live_off is not None and res["dropped_refreshes"]:
        g0 = next(((a, b) for a, b in zip(ts, ts[1:]) if b - a > 1.5 * period))
        defects.append({"kind": "dropped-refresh", "t": round(g0[0], 4), "t_end": g0[1], "frames": res["dropped_refreshes"],
                        "detail": {"gaps_ms": [round(g * 1000, 1) for g in gaps]}})
    for d in defects:
        d["t_end"] = round(d["t_end"], 4)
    res["defects"] = defects
    res["pass"] = not defects and first_tgt is not None and res.get("photon_refreshes", 99) <= 1
    res["verdict"] = "PASS" if res["pass"] else "FAIL"
    res["timeline"] = [{"t": round(f.t, 4), "content": f.label, "sidebar": f.side} for f in out_frames[:40]]
    return res


def judge(video: str, events: list[dict], hz: float, sidebar_right: int | None, times: list[float] | None = None):
    events = sorted(events, key=lambda e: e["t"])
    windows = []
    for ev in events:
        a = ev["t"] - float(ev.get("pre", 0.25))
        b = ev["t"] + max(float(ev.get("settle_end", 0.9)), float(ev.get("window", 0.6)))
        windows.append((a, b))
    buf: list[tuple[float, np.ndarray, np.ndarray | None]] = []
    results = []
    ei = 0
    for t, rgb in read_video(video, windows, times):
        while ei < len(events) and t > windows[ei][1]:
            results.append(judge_event(events[ei], buf, hz, sidebar_right))
            buf = [b for b in buf if ei + 1 < len(events) and b[0] >= windows[ei + 1][0]]
            ei += 1
        if ei >= len(events):
            break
        buf.append((t, tiles(downscale(rgb)), rgb))
    while ei < len(events):
        results.append(judge_event(events[ei], buf, hz, sidebar_right))
        ei += 1
    return results


def summary(results: list[dict]) -> dict:
    vals = sorted(r["photon_refreshes"] for r in results if "photon_refreshes" in r)

    def pct(p):
        if not vals:
            return None
        return vals[min(len(vals) - 1, max(0, math.ceil(p / 100 * len(vals)) - 1))]

    kinds: dict[str, int] = {}
    for r in results:
        for d in r["defects"]:
            kinds[d["kind"]] = kinds.get(d["kind"], 0) + 1
    return {"n": len(results), "judged": len(vals), "p50": pct(50), "p95": pct(95), "max": vals[-1] if vals else None,
            "pass": sum(1 for r in results if r.get("pass")), "defects": kinds}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True)
    ap.add_argument("--events", required=True)
    ap.add_argument("--out")
    ap.add_argument("--hz", type=float, default=120.0)
    ap.add_argument("--sidebar-right", type=int, default=None, help="sidebar right edge in video pixels")
    ap.add_argument("--frames", help="the recorder's PATH.frames.json: frame times and event times in host seconds")
    args = ap.parse_args()
    ev = json.load(open(args.events))
    if isinstance(ev, dict):
        ev = ev["events"]
    results = judge(args.video, ev, args.hz, args.sidebar_right, movie_times(args.frames) if args.frames else None)
    out = {"video": args.video, "hz": args.hz, "summary": summary(results), "events": results}
    text = json.dumps(out, indent=1, default=str)
    if args.out:
        Path(args.out).write_text(text)
    print(json.dumps(out["summary"]))
    for r in results:
        print(f"{r.get('case')}: {r['verdict']} photon {r.get('photon_refreshes')} refreshes "
              f"({r.get('photon_ms')} ms); defects: " + ", ".join(f"{d['kind']}@{d['t']:.3f}s x{d['frames']}" for d in r["defects"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
