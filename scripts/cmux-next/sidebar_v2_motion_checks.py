"""Frame checks for sidebar-v2 drag recordings (DESIGN.md "Drag feel").

Shared by sidebar-v2-drag-record.py (live) and the proof page builder
(offline over motion.json). Each frame is {t, lift, work_ms, views:
{key: [x, y, w, h, opacity?]}, revision?, settling?} from
`debug.sidebar_rows {"motion": "stop"}`.

The drag work percentiles and the cadence (the median frame gap) are scripts/perf-lab/perf_stats.py's pct (linear interpolation, the one the perf lab judges
with), loaded by file path so the module also imports under `python3 -I`.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import PERF_LAB, load_by_path  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))

JUMP_PT = 8.0
SETTLE_PT = 1.0
WORK_P95_MS = 4.0  # the `work` check: the main-thread drag update p95 stays under it (stories.d/sidebar-drag.json refers to it)


def rect(view):
    return view[:4]


def drawn(view):
    """Drawn at all (a hidden row of a dragged group, or a row faded out, is not)."""
    return (view[4] if len(view) > 4 else 1) > 0.02


FRAME_MS = 1000 / 120


def covered(frame, card):
    return card is not None and all(abs(frame[i] - card[i]) <= 1.5 for i in range(4))


def scroll_of(frames, i):
    return frames[i].get("scroll", 0) if 0 <= i < len(frames) else frames[0].get("scroll", 0)


def y_step(frames, i, ya, yb):
    """The least vertical move of a view from frame i-1 to frame i: in list (document) coordinates, or on
    screen (minus `scroll`). An anchored shift (rows and offset move together) moves nothing on screen; a
    scroll with rows in place moves nothing in the list. The views are presented frames and `scroll` is the
    clip's model offset, so a non-animated shift can show the offset one frame before the rows: the screen
    step is also taken with both frames one offset behind."""
    doc = abs(yb - ya)
    screen = abs((yb - scroll_of(frames, i)) - (ya - scroll_of(frames, i - 1)))
    lagged = abs((yb - scroll_of(frames, i - 1)) - (ya - scroll_of(frames, i - 2)))
    return min(doc, screen, lagged)


def drag_work(frames):
    """The main-thread drag update time of each frame that did one (work_ms > 0), in frame order: the samples of the
    `work` check and of the recorder's result-v1 series."""
    return [f["work_ms"] for f in frames if f["work_ms"] > 0]


def analyse(frames, dragged, dropped_key=None, refused=False, hz=120):
    worst, worst_at, jumps, block_worst, raw_worst = 0.0, None, [], 0.0, 0.0
    scroll_worst = 0.0
    for i, (a, b) in enumerate(zip(frames, frames[1:]), start=1):
        if not (a["lift"] or b["lift"]):
            # A scroll step outside a drag (a reveal, a wheel): reported, not a jump (the offset is the model's, an
            # animated reveal shows its target at once).
            scroll_worst = max(scroll_worst, abs(scroll_of(frames, i) - scroll_of(frames, i - 1)))
        for key, fb in b["views"].items():
            fa = a["views"].get(key)
            if fa is None or key in dragged or not (drawn(fa) or drawn(fb)):
                continue
            # A step per 120 Hz frame: a display frame that came late (a gap of n frames) may move n frames' worth.
            frames_spanned = max(1.0, (b["t"] - a["t"]) * 1000 / FRAME_MS)
            raw = max(abs(fb[0] - fa[0]), y_step(frames, i, fa[1], fb[1]), abs(fb[3] - fa[3]))
            step = raw / frames_spanned
            # The undivided step across a late frame (more than 2 frames apart), reported beside the per-frame one.
            if frames_spanned > 2:
                raw_worst = max(raw_worst, raw)
            if key.startswith("block("):
                block_worst = max(block_worst, abs(fb[3] - fa[3]) / frames_spanned)
            if step > worst:
                worst, worst_at = step, (key, round(b["t"] - frames[0]["t"], 3))
            if step > JUMP_PT:
                jumps.append({"key": key, "t": round(b["t"] - frames[0]["t"], 3), "step": round(step, 1)})
    work = drag_work(frames)
    p95 = perf_stats.pct(work, 0.95) if work else 0
    p99 = perf_stats.pct(work, 0.99) if work else 0
    gaps = [b["t"] - a["t"] for a, b in zip(frames, frames[1:])]
    cadence = perf_stats.pct(gaps, 0.5) * 1000 if gaps else 0  # the median
    lifted = [f for f in frames if f["lift"]]
    if lifted and not dropped_key:
        # The dropped item: a key that shows after the drop and not at the start, else the dragged row itself.
        new = [k for k in frames[-1]["views"] if k not in frames[0]["views"]]
        dropped_key = new[0] if len(new) == 1 else next(iter(dragged & set(frames[-1]["views"])), None)
    settle = None
    if lifted and dropped_key:
        last = lifted[-1]
        after = [f for f in frames if f["t"] > last["t"] and dropped_key in f["views"] and drawn(f["views"][dropped_key])]
        if after:
            card, shown = last["lift"], after[0]["views"]
            # The landing target: the dropped item with the dragged views that show after the drop, then the rows
            # hidden under the card that show with them right below or above (a group's visible members).
            keys = [dropped_key] + [k for k in sorted(dragged) if k != dropped_key and k in shown and drawn(shown[k])]

            def union(ks):
                rs = [rect(shown[k]) for k in ks]
                x0, y0 = min(r[0] for r in rs), min(r[1] for r in rs)
                return [x0, y0, max(r[0] + r[2] for r in rs) - x0, max(r[1] + r[3] for r in rs) - y0]
            item = union(keys)
            grew = True
            while grew:
                grew = False
                for key, view in shown.items():
                    before = last["views"].get(key)
                    if key in keys or key.startswith(("block(", "item:")) or not drawn(view) or before is None or drawn(before):
                        continue
                    if view[1] <= item[1] + item[3] + 4 and view[1] + view[3] >= item[1] - 4:
                        keys.append(key)
                        item, grew = union(keys), True
            meet = max(abs(card[i] - item[i]) for i in range(4))
            drift = max((max(abs(b["views"][k][i] - a["views"][k][i]) for i in range(4))
                         for k in keys for a, b in zip(after, after[1:]) if k in a["views"] and k in b["views"]), default=0)
            settle = {"key": dropped_key, "keys": keys, "card_meets_item_pt": round(meet, 2), "item_max_step_after_pt": round(drift, 2),
                      "ok": meet < SETTLE_PT and drift <= 0.5}
    # The echo: every model revision change after the release (the optimistic model, then the daemon's batch).
    # The release: the first settling frame (document drops), else the frame after the card's last pointer-driven move
    # (work_ms changes only while the pointer moves).
    release = next((i for i, f in enumerate(frames) if i and frames[i - 1]["lift"] and f.get("settling")), None)
    if release is None:
        moves = [i for i in range(1, len(frames)) if frames[i]["work_ms"] != frames[i - 1]["work_ms"]]
        release = moves[-1] + 1 if moves else None
    echo = None
    if frames and "revision" in frames[0]:
        changes = [i for i in range(1, len(frames)) if frames[i]["revision"] != frames[i - 1]["revision"] and (release is None or i >= release)]
        kinks, pops, coarse = [], [], 0
        for i in changes:
            # A change sampled more than 2 frames apart on either side: a one-frame snap there reads smaller per frame.
            if i >= 2 and max(frames[i]["t"] - frames[i - 1]["t"], frames[i - 1]["t"] - frames[i - 2]["t"]) * 1000 > 2 * FRAME_MS:
                coarse += 1
            card = frames[i]["lift"] or frames[i - 1]["lift"]
            for key, fb in frames[i]["views"].items():
                if key in dragged:
                    continue
                fa = frames[i - 1]["views"].get(key)
                visible = (fb[4] if len(fb) > 4 else 1) > 0.02
                if fa is None:
                    if visible and not covered(fb, card):
                        pops.append({"key": key, "t": round(frames[i]["t"] - frames[0]["t"], 3), "kind": "appears"})
                    continue
                f0 = frames[i - 2]["views"].get(key) if i >= 2 else None
                if f0 is not None:
                    # The kink is the change of velocity per 120 Hz frame, in pt per frame per frame (as a jump is a step per frame): a late
                    # sample (a Debug build under 1,000 rows: 90-130 ms between samples) of a spring that settles is
                    # not a kink, a change the echo makes in one frame is (cx-8quut).
                    n1 = max(1.0, (frames[i - 1]["t"] - frames[i - 2]["t"]) * 1000 / FRAME_MS)
                    n2 = max(1.0, (frames[i]["t"] - frames[i - 1]["t"]) * 1000 / FRAME_MS)

                    # Velocity change per frame between the two intervals' midpoints ((n1 + n2) / 2 frames apart): a
                    # second difference per frame squared, the same for a smooth spring at any sampling.
                    def bend(d0, d1):
                        return abs(d1 / n2 - d0 / n1) / max(1.0, (n1 + n2) / 2)
                    kink = max(bend(fa[j] - f0[j], fb[j] - fa[j]) for j in (0, 3))
                    # The vertical kink in the list or on screen (minus `scroll`), the smaller: an anchored shift is no kink.
                    s0, s1, s2 = scroll_of(frames, i - 2), scroll_of(frames, i - 1), scroll_of(frames, i)
                    sl = scroll_of(frames, i - 3)
                    kink = max(kink, min(bend(fa[1] - f0[1], fb[1] - fa[1]),
                                         bend((fa[1] - s1) - (f0[1] - s0), (fb[1] - s2) - (fa[1] - s1)),
                                         bend((fa[1] - s0) - (f0[1] - sl), (fb[1] - s1) - (fa[1] - s0))))
                    if kink > 1:
                        kinks.append({"key": key, "t": round(frames[i]["t"] - frames[0]["t"], 3), "kink": round(kink, 1)})
            for key, fa in frames[i - 1]["views"].items():
                if key not in frames[i]["views"] and key not in dragged and (fa[4] if len(fa) > 4 else 1) > 0.02 and not covered(fa, card):
                    pops.append({"key": key, "t": round(frames[i]["t"] - frames[0]["t"], 3), "kind": "vanishes"})
        echo = {"revision_changes": len(changes), "coarse_changes": coarse, "kinks": kinks[:10], "pops": pops[:10],
                "ok": not kinks and not pops}
    result = {"frames": len(frames), "cadence_ms": round(cadence, 2), "max_step_pt": round(worst, 1), "raw_max_step_pt": round(raw_worst, 1), "max_step_at": worst_at, "jumps": jumps[:20],
              "jump_count": len(jumps), "block_height_max_step_pt": round(block_worst, 1),
              "scroll_max_step_outside_drag_pt": round(scroll_worst, 1), "drag_work_p95_ms": round(p95, 2),
              "drag_work_p99_ms": round(p99, 2),
              "frame_gaps_over_1_5x": sum(1 for g in gaps if g > 1.5 / hz), "settle": settle, "echo": echo, "refused": refused,
              "dragged": sorted(dragged)}
    # Nothing recorded, no lifted card or no dropped item to follow is a failed proof, not a pass.
    recorded = len(frames) >= 10 and bool(lifted)
    result["recorded"] = recorded
    result["ok"] = bool(recorded and not jumps and block_worst <= JUMP_PT and p95 < WORK_P95_MS and settle is not None and settle["ok"]
                        and (echo is None or echo["ok"]))
    return result


def infer_dragged(frames):
    """The views under the card when it lifts (for recordings that did not name them)."""
    lifted = next((f for f in frames if f.get("lift")), None)
    if not lifted:
        return set()
    x, y, w, h = lifted["lift"][:4]
    return {k for k, v in lifted["views"].items() if v[0] >= x - 3 and v[1] >= y - 3 and v[0] + v[2] <= x + w + 3 and v[1] + v[3] <= y + h + 3}
