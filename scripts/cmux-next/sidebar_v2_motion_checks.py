"""Frame checks for sidebar-v2 drag recordings (DESIGN.md "Drag feel").

Shared by sidebar-v2-drag-record.py (live) and the proof page builder
(offline over motion.json). Each frame is {t, lift, work_ms, views:
{key: [x, y, w, h, opacity?]}, revision?, settling?} from
`debug.sidebar_rows {"motion": "stop"}`.
"""
import statistics

JUMP_PT = 8.0
SETTLE_PT = 1.0


def rect(view):
    return view[:4]


def drawn(view):
    """Drawn at all (a hidden row of a dragged group, or a row faded out, is not)."""
    return (view[4] if len(view) > 4 else 1) > 0.02


FRAME_MS = 1000 / 120


def covered(frame, card):
    return card is not None and all(abs(frame[i] - card[i]) <= 1.5 for i in range(4))


def analyse(frames, dragged, dropped_key=None, refused=False, hz=120):
    worst, worst_at, jumps, block_worst = 0.0, None, [], 0.0
    for a, b in zip(frames, frames[1:]):
        for key, fb in b["views"].items():
            fa = a["views"].get(key)
            if fa is None or key in dragged or not (drawn(fa) or drawn(fb)):
                continue
            # A step per 120 Hz frame: a display frame that came late (a gap of n frames) may move n frames' worth.
            frames_spanned = max(1.0, (b["t"] - a["t"]) * 1000 / FRAME_MS)
            step = max(abs(fb[0] - fa[0]), abs(fb[1] - fa[1]), abs(fb[3] - fa[3])) / frames_spanned
            if key.startswith("block("):
                block_worst = max(block_worst, abs(fb[3] - fa[3]) / frames_spanned)
            if step > worst:
                worst, worst_at = step, (key, round(b["t"] - frames[0]["t"], 3))
            if step > JUMP_PT:
                jumps.append({"key": key, "t": round(b["t"] - frames[0]["t"], 3), "step": round(step, 1)})
    work = sorted(f["work_ms"] for f in frames if f["work_ms"] > 0)
    p95 = work[int(len(work) * 0.95)] if work else 0
    gaps = [b["t"] - a["t"] for a, b in zip(frames, frames[1:])]
    cadence = statistics.median(gaps) * 1000 if gaps else 0
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
            card, item = last["lift"], rect(after[0]["views"][dropped_key])
            meet = max(abs(card[i] - item[i]) for i in range(4))
            drift = max((max(abs(b["views"][dropped_key][i] - a["views"][dropped_key][i]) for i in range(4))
                         for a, b in zip(after, after[1:]) if dropped_key in a["views"] and dropped_key in b["views"]), default=0)
            settle = {"key": dropped_key, "card_meets_item_pt": round(meet, 2), "item_max_step_after_pt": round(drift, 2),
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
        kinks, pops = [], []
        for i in changes:
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
                    kink = max(abs((fb[j] - fa[j]) - (fa[j] - f0[j])) for j in (0, 1, 3))
                    if kink > 1:
                        kinks.append({"key": key, "t": round(frames[i]["t"] - frames[0]["t"], 3), "kink": round(kink, 1)})
            for key, fa in frames[i - 1]["views"].items():
                if key not in frames[i]["views"] and key not in dragged and (fa[4] if len(fa) > 4 else 1) > 0.02 and not covered(fa, card):
                    pops.append({"key": key, "t": round(frames[i]["t"] - frames[0]["t"], 3), "kind": "vanishes"})
        echo = {"revision_changes": len(changes), "kinks": kinks[:10], "pops": pops[:10], "ok": not kinks and not pops}
    result = {"frames": len(frames), "cadence_ms": round(cadence, 2), "max_step_pt": round(worst, 1), "max_step_at": worst_at, "jumps": jumps[:20],
              "jump_count": len(jumps), "block_height_max_step_pt": round(block_worst, 1), "drag_work_p95_ms": round(p95, 2),
              "frame_gaps_over_1_5x": sum(1 for g in gaps if g > 1.5 / hz), "settle": settle, "echo": echo, "refused": refused,
              "dragged": sorted(dragged)}
    # Nothing recorded, no lifted card or no dropped item to follow is a failed proof, not a pass.
    recorded = len(frames) >= 10 and bool(lifted)
    result["recorded"] = recorded
    result["ok"] = bool(recorded and not jumps and block_worst <= JUMP_PT and p95 < 4 and settle is not None and settle["ok"]
                        and (echo is None or echo["ok"]))
    return result


def infer_dragged(frames):
    """The views under the card when it lifts (for recordings that did not name them)."""
    lifted = next((f for f in frames if f.get("lift")), None)
    if not lifted:
        return set()
    x, y, w, h = lifted["lift"][:4]
    return {k for k, v in lifted["views"].items() if v[0] >= x - 3 and v[1] >= y - 3 and v[0] + v[2] <= x + w + 3 and v[1] + v[3] <= y + h + 3}
