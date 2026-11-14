#!/usr/bin/env python3
"""Independent oracle for sidebar row insert and remove films (cmux-ad m23, STATUS 14191).

  python3 scripts/cmux-next/sidebar_row_oracle.py FILM_DIR_OR_JSON [--json OUT] [--scale 2] [--tolerance-px 1] [--motion grow|snap]

It judges the contract of the INSTANT OWNER for a new workspace row (insert) and a closed one (remove): the new row
grows from height 0; the closing row shrinks to 0; every row below moves on one curve (same start frame, same
progress per frame); no re-wrap or flicker; no row view rebuilt during the motion; the selection follows its row;
120 Hz with 0 missed refreshes. It is written outside the INSTANT OWNER (m21 judge guard) and reads only the film.

Input: the per-display-frame film of `debug.sidebar_rows {"motion": "start"|"stop"}` (SidebarMotionProbe): frames
[{t, scroll, views: {key: [x, y, w, h, opacity]}, ...}], presented frames in list coordinates (points, y down). Optional
fields a later probe can add, each used when present: `link` / `target` / `refresh` (the display link's tick), `ids`
{key: view id}, `selected` (the key that shows the selection) and `selection` ([x, y, w, h] of the highlight), and
`scale` (the backing scale). Files: samples.json of scripts/cmux-next/sidebar-instant-rows-live.py ({pressed, samples,
motion}), film-*.json of scripts/journeys/ext_sidebar_film.py ({presses: [{kind, frames, rows_before, rows_after}]}, one
film per press), a motion report ({frames}) or a list of frames. A folder is searched for these files.

The expected place of every row in every frame:
  - A motion is a run of frames where the set of rows or a row's y or height changes. The run where one row opens or
    closes takes in the runs next to it while they bring the rows below to their place (they still miss the row's slot
    and that run moves them most of the rest of the way), so rows that open the gap before the new row shows or slide
    after the closing row is gone are judged on its curve; other changes keep their own window. Its start frame s is the last still frame before
    it, its end frame e the first frame of the settled layout; y0 and y1 are a row's y in s and e. Positions are in
    list coordinates: a scroll during the motion is not judged (the films keep the scroll fixed).
  - Rows that moved (|y1 - y0| x scale >= 0.5 device px) share one progress p per frame, fitted by least squares:
    p = sum(D (y - y0)) / sum(D^2) with D = y1 - y0. A row's error = |y - (y0 + p D)| x scale in device px. Rows that
    did not move must stay at y0.
  - The new row (not in s, in e) has height p x its final height; the closing row (in s, not in e) has height
    (1 - p) x its start height; a frame that does not show the row counts as height 0 (also for p when no other row
    moves). Rows the row lists name as new or closed that never open or close in the film FAIL when their place is
    inside the rows the film shows (outside it: a note). Their edge away from the rows
    that move stays where it ends (new row) or starts (closing row).
  - A curve shows each refresh: p may not cover more than half the motion in one refresh, nor go from start (<= 0.05)
    to end (>= 0.95) with no frame between (a jump: nothing grows).
  - Missed refreshes: frame intervals over 1.5 display periods inside a motion across which a shown row moves or the
    new or closing row shows or leaves (a row realized or pruned at the list edge alone is not motion); an interval misses
    round(gap / period) - 1 refreshes. Period: --period-ms, else the probe's `refresh`, else the median interval,
    else 8.333 ms. Clock: `target`, else `link`, else `t` (`t` is when the main thread read the frame: its jitter can
    add or hide a miss).
  - Rebuilt rows: with `ids`, a key whose view id changes. Without `ids`, what the film can show: a key that leaves
    and comes back, an opacity that falls to 0 and comes back, or a row that jumps off the curve; the output then
    says that identity was not available.
  - Flicker: the opacity of a row other than the new or closing row changes. Re-wrap: a row's x or width changes.
  - Selection: with per-frame `selected` / `selection`, the highlight keeps its offset to its row and the selected key
    changes at most once per motion; without them, "not recorded".
  - --motion snap (the film was recorded with sidebar.insertMotion snap, the app's default since #28205; the lead's
    ruling, STATUS 15439: the grow and shrink clauses above apply to the grow value only): a new row's fade is its
    motion (its window runs until its opacity stops changing, and an interval across which it changes can miss a
    refresh). Every row is at its start or its end slot in every frame, and stays once at its end (no slide); the rows
    below the new row change slot in one frame; the new row draws (a zero-size view draws nothing) at its slot at full
    height, first in the frame the rows below make room (before: an overlap; after: a gap); its opacity starts below
    0.95 (a fade, not a pop-in), rises each refresh until 0.95 (an equal value is a held fade frame) and never falls by
    more than 0.01. A remove takes the same path under both values (SidebarRowTransition.removeFrame:
    the closing row closes to height 0 on the rows' spring), so it is judged as in grow. Missed refreshes, rebuilt rows,
    flicker, re-wrap and the selection are judged the same in both modes. Default: --motion grow.
  - A press with no user intent (film press `mode` "noswitch": a script's change, focus false) shows in one step under
    the calm-movement rule (plans/cmux-next/sidebar-calm-movement.md, Lawrence 2026-10-20; SidebarListView.showModelChange):
    it is judged as instant under any --motion. Every row is at its start or its end slot and all of them, the new row
    (at full height, opacity >= 0.95) and the closing row (gone) change in one frame; missed refreshes, rebuilt rows,
    flicker, re-wrap and the selection as always.
  - Values: each row view's frame and opacity from its layer's presentation (CALayer.presentation(), read on the main
    thread at the display frame tick by SidebarMotionProbe), not pixels; the report says so (`values`).
Frame numbers are indexes into the film's frames. Exit 0 PASS, 1 FAIL, 2 not judged (no motion, cut motion, not
120 Hz, no film). Not a CI job, step or gate: the INSTANT OWNER and pixel-perfect run it on their films.
"""
import argparse
import json
import math
import os
import statistics
import sys

MISS_FACTOR = 1.5
DEFAULT_PERIOD_S = 1 / 120
CHANGE_EPS_PT = 1e-6  # a row's y or height changed between two frames (motion segmentation; layers at rest are exact)
MERGE_FRAMES = 6  # changes this few still frames apart are one motion
MOVER_PX = 0.5  # a row moved over a motion when |y1 - y0| x scale is at least this
START_EPS_PT = 1e-3  # a row started to move when it left its start by more than this
GROWN_FRACTION = 0.5  # a row first shown at most this part of its final height grows from 0
MAX_PROGRESS_STEP = 0.5  # more of the motion than this in one refresh is a jump, not a curve
END_FRACTION = 0.95  # a step from p <= 0.05 to p >= 0.95 shows no frame between start and end
OPACITY_LOW, OPACITY_HIGH, FLICKER_OPACITY = 0.05, 0.95, 0.05
FADE_BACK_EPS = 0.01  # snap: the new row's opacity may not fall by more than this from one frame to the next
MOTIONS = ("grow", "snap")
NO_INTENT_MODES = ("noswitch",)  # film press modes of a change no user in the window asked for (calm-movement rule)
VALUES = ("each row view's frame and opacity from its layer's presentation (CALayer.presentation(), read on the main thread "
          "at the display frame tick by SidebarMotionProbe), not pixels")
LIST_CAP = 400  # entries kept per list in the JSON
ORDER = ["FAIL", "INVALID", "INCOMPLETE", "NO MOTION", "PASS"]
NO_IDENTITY = "not available: rebuilt rows judged from presence, opacity and jumps (the probe has no view ids)"


class Options:
    def __init__(self, scale=None, tolerance_px=1.0, period_ms=None, expect_hz=120.0, inserted=None, closed=None, motion="grow"):
        self.scale, self.tolerance_px, self.period_ms, self.expect_hz = scale, tolerance_px, period_ms, expect_hz
        self.inserted, self.closed = inserted, closed
        self.motion = motion  # the sidebar.insertMotion value the film was recorded with: grow (the m23 clauses) or snap


def is_num(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def is_row(key):
    """A list row (workspace, tab, group...), not an item inside a block row."""
    return not key.startswith("item:")


def rounded(value, digits=3):
    return None if value is None else round(value, digits)


# ---------------------------------------------------------------- input


def normalize(raw_frames):
    frames = []
    for raw in raw_frames:
        raw = raw if isinstance(raw, dict) else {}
        views = {}
        for key, box in (raw.get("views") or {}).items():
            if isinstance(box, (list, tuple)) and len(box) >= 4 and all(is_num(v) for v in box[:4]):
                opacity = float(box[4]) if len(box) > 4 and is_num(box[4]) else 1.0
                views[str(key)] = tuple(float(v) for v in box[:4]) + (opacity,)
        ids = raw.get("ids")
        frames.append({"raw": raw, "views": views,
                       "ids": {str(k): str(v) for k, v in ids.items()} if isinstance(ids, dict) else None})
    return frames


def row_geometry(rows):
    """{key: (y, h)} from a row list (film harness rows_before/after: y, h; recorder samples: frame {y, height})."""
    out = {}
    for row in rows or []:
        if not isinstance(row, dict) or not row.get("key"):
            continue
        frame = row.get("frame") if isinstance(row.get("frame"), dict) else {}
        y, h = row.get("y", frame.get("y")), row.get("h", frame.get("height"))
        out[str(row["key"])] = (float(y), float(h)) if is_num(y) and is_num(h) else None
    return out


def hints_from_rows(before, after):
    hints = {}
    if before is not None and after is not None:
        b, a = row_geometry(before), row_geometry(after)
        hints.update(inserted=set(a) - set(b), closed=set(b) - set(a), rows_before=b, rows_after=a)
    return hints


def films_from_json(data, name):
    """[(name, raw frames, hints)] for each film in a parsed JSON value (empty when it holds none)."""
    if isinstance(data, list):
        return [(name, data, {})] if data and all(isinstance(f, dict) and "views" in f for f in data) else []
    if not isinstance(data, dict):
        return []
    scale = data.get("scale") if is_num(data.get("scale")) else None
    if isinstance(data.get("presses"), list):  # ext_sidebar_film.py: one film per press
        films = []
        for index, press in enumerate(data["presses"]):
            if isinstance(press, dict) and isinstance(press.get("frames"), list):
                hints = hints_from_rows(press.get("rows_before"), press.get("rows_after"))
                hints.update(kind=press.get("kind"), scale=scale, mode=press.get("mode"))
                label = f"{name}#{press.get('index', index)} {press.get('kind') or ''}".strip()
                films.append((label, press["frames"], hints))
        return films
    motion = data.get("motion")
    if isinstance(motion, dict) and isinstance(motion.get("frames"), list):  # sidebar-instant-rows-live.py samples.json
        hints = {"scale": scale}
        pressed = [p for p in data.get("pressed") or [] if isinstance(p, (list, tuple)) and p and is_num(p[0])]
        samples = [s for s in data.get("samples") or [] if isinstance(s, (list, tuple)) and len(s) >= 2 and is_num(s[0])]
        if pressed and samples:
            first = min(p[0] for p in pressed)
            before = [s for s in samples if s[0] < first]
            if before and samples[-1][0] > first:
                hints.update(hints_from_rows(before[-1][1], samples[-1][1]))
        return [(name, motion["frames"], hints)]
    if isinstance(data.get("frames"), list):
        return [(name, data["frames"], {"scale": scale})]
    return []


def load_films(path):
    if os.path.isdir(path):
        found = []
        for folder, dirs, files in os.walk(path):
            dirs.sort()
            for file in sorted(files):
                if not file.endswith(".json"):
                    continue
                full = os.path.join(folder, file)
                try:
                    with open(full) as handle:
                        data = json.load(handle)
                except (OSError, ValueError):
                    continue
                found += films_from_json(data, os.path.relpath(full, path))
        return found
    with open(path) as handle:
        return films_from_json(json.load(handle), os.path.basename(path))


# ---------------------------------------------------------------- judge


def changed(a, b):
    """Whether the rows (not block items) or a row's y or height differ between two frames."""
    ka, kb = {k for k in a if is_row(k)}, {k for k in b if is_row(k)}
    if ka != kb:
        return True
    return any(abs(a[k][1] - b[k][1]) > CHANGE_EPS_PT or abs(a[k][3] - b[k][3]) > CHANGE_EPS_PT for k in ka)


def moves_across(a, b, events, fading=()):
    """Whether the motion shows between two frames: a row shown in both changes its y or height, or a new or closing
    row (EVENTS) appears or leaves. A row realized or pruned at the list edge alone is not motion."""
    for k in a.keys() & b.keys():
        if is_row(k) and (abs(a[k][1] - b[k][1]) > CHANGE_EPS_PT or abs(a[k][3] - b[k][3]) > CHANGE_EPS_PT):
            return True
    if any(k in a and k in b and abs(a[k][4] - b[k][4]) > CHANGE_EPS_PT for k in fading):
        return True  # --motion snap: the new row's fade is its motion
    return any((k in a) != (k in b) for k in events)


def motions(frames):
    """[(s, e)]: s the last still frame before a motion, e the first frame of its settled layout."""
    changes = [i for i in range(1, len(frames)) if changed(frames[i - 1]["views"], frames[i]["views"])]
    runs = []
    for i in changes:
        if runs and i - runs[-1][1] <= MERGE_FRAMES:
            runs[-1][1] = i
        else:
            runs.append([i, i])
    return [(first - 1, last) for first, last in runs]


def slot_deficit(frames, gs, ge, key, sign, slot):
    """How far the rows below KEY still are from their place after frames gs..ge: the median over them of
    sign x slot - (y at ge - y at gs), in points (None when no row below shows at both ends)."""
    views = frames[gs]["views"]
    anchor = frames[ge]["views"].get(key) or views.get(key)
    if anchor is None:
        return None
    y_key = anchor[1]
    rest = []
    for k, box in views.items():
        if k == key or not is_row(k) or k not in frames[ge]["views"]:
            continue
        if (box[1] >= y_key - 0.5) if sign > 0 else (box[1] > y_key + 0.5):
            rest.append(sign * slot - (frames[ge]["views"][k][1] - box[1]))
    return statistics.median(rest) if rest else None


def windows(frames, hints, snap=False):
    """[(s, e)]: the motions. A run where one row opens or closes takes in the runs next to it (before or after) while
    they bring the rows below it to their place: they still miss the new or closing row's slot (its height and the
    row spacing) and that run moves them most of the rest of the way. So rows that open the gap before the new row
    shows, or slide after the closing row is gone, are judged on its curve; any other change (a row that grows, a row
    realized or pruned at the list edge, a later press) keeps its own window."""
    runs = motions(frames)
    events = [pick_events(frames, s, e, hints, snap)[:2] for s, e in runs]
    used, out = set(), []
    for index, ((s, e), (inserted, closed)) in enumerate(zip(runs, events)):
        if index in used:
            continue
        if len(inserted) + len(closed) != 1:
            out.append((s, e))
            continue
        key, sign = (inserted[0], 1) if inserted else (closed[0], -1)
        box = frames[e]["views"].get(key) if inserted else frames[s]["views"].get(key)
        if box is None:
            out.append((s, e))
            continue
        shown = sorted((v[1], v[3]) for k, v in frames[s]["views"].items() if is_row(k) and k != key and v[3] > 0)
        gaps = [b[0] - a[0] - a[1] for a, b in zip(shown, shown[1:]) if b[0] - a[0] - a[1] >= 0]
        slot = box[3] + (statistics.median(gaps) if gaps else 0.0)
        gs, ge, lo, hi = s, e, index, index
        for step in (1, -1):
            while True:
                j = (hi if step > 0 else lo) + step
                if not 0 <= j < len(runs) or j in used or any(events[j]):
                    break
                before = slot_deficit(frames, gs, ge, key, sign, slot)
                after = slot_deficit(frames, gs, runs[j][1], key, sign, slot) if step > 0 else \
                    slot_deficit(frames, runs[j][0], ge, key, sign, slot)
                if before is None or after is None or abs(before) <= 0.25 * slot or abs(after) > 0.5 * abs(before):
                    break
                used.add(j)
                if step > 0:
                    hi, ge = j, runs[j][1]
                else:
                    lo, gs = j, runs[j][0]
        if snap and inserted:
            ge = fade_end(frames, ge, key, min((runs[j][0] for j in range(hi + 1, len(runs)) if j not in used), default=len(frames) - 1))
        out.append((gs, ge))
    return sorted(out)


def fade_end(frames, ge, key, limit):
    """--motion snap: the frame from which KEY's opacity no longer changes (its fade is its motion), from GE to at most
    LIMIT (the next motion's start frame): the window of a snap insert ends when its new row has faded in."""
    end = ge
    for j in range(ge + 1, min(limit, len(frames) - 1) + 1):
        a, b = frames[j - 1]["views"].get(key), frames[j]["views"].get(key)
        if a is None or b is None:
            break
        if abs(a[4] - b[4]) > CHANGE_EPS_PT:
            end = j
    return end


def between(frame_views, key):
    """Whether rows show on both sides of KEY in this frame (it opened or closed inside the list, not at a list edge)."""
    y = frame_views[key][1]
    others = [v[1] for k, v in frame_views.items() if k != key and is_row(k)]
    return any(o < y for o in others) and any(o > y for o in others)


def pick_events(frames, s, e, hints, snap=False):
    """(new rows, closing rows, notes): rows that open or close in this motion."""
    window = range(s, e + 1)
    start, end = frames[s]["views"], frames[e]["views"]
    seen = sorted({k for i in window for k in frames[i]["views"] if is_row(k)})
    first = {k: next(i for i in window if k in frames[i]["views"]) for k in seen}
    last = {k: next(i for i in reversed(window) if k in frames[i]["views"]) for k in seen}
    scale_eps = 1e-6
    appeared = [k for k in seen if k not in start and k in end]
    appeared += [k for k in seen if k in start and k in end and start[k][3] <= scale_eps < end[k][3]]
    left = [k for k in seen if k in start and k not in end]
    left += [k for k in seen if k in start and k in end and end[k][3] <= scale_eps < start[k][3]]
    notes = []
    if hints.get("inserted") is not None or hints.get("closed") is not None:
        want_in, want_out = set(hints.get("inserted") or ()), set(hints.get("closed") or ())
        inserted = [k for k in appeared if k in want_in]
        closed = [k for k in left if k in want_out]
        for k in sorted(want_in - set(inserted)):
            notes.append(f"new row {k} (from the row lists) did not open in frames {s}-{e}")
        for k in sorted(want_out - set(closed)):
            notes.append(f"closed row {k} (from the row lists) did not close in frames {s}-{e}")
        return inserted, closed, notes
    def grows(k):
        return frames[first[k]]["views"][k][3] <= GROWN_FRACTION * end[k][3]
    def shrinks(k):
        return frames[last[k]]["views"][k][3] <= GROWN_FRACTION * start[k][3]
    def fades(k):  # --motion snap: a new row shows at full height and fades in (its first laid-out frame)
        drawn = [i for i in window if k in frames[i]["views"] and frames[i]["views"][k][3] > scale_eps]
        return snap and bool(drawn) and frames[drawn[0]]["views"][k][4] < OPACITY_HIGH
    inserted = [k for k in appeared if grows(k) or fades(k) or between(frames[first[k]]["views"], k)]
    closed = [k for k in left if shrinks(k) or between(frames[last[k]]["views"], k)]
    if appeared or left:
        notes.append("no row lists: new and closing rows found from the film alone")
    return inserted, closed, notes


def judge_motion(frames, s, e, times, period, opts, scale, identity, hints):
    tol = opts.tolerance_px
    window = range(s, e + 1)
    start, end = frames[s]["views"], frames[e]["views"]
    instant = hints.get("mode") in NO_INTENT_MODES
    snap_mode = getattr(opts, "motion", "grow") == "snap" and not instant
    inserted, closed, notes = pick_events(frames, s, e, hints, snap_mode or instant)
    events = set(inserted) | set(closed)
    seen = sorted({k for i in window for k in frames[i]["views"]})
    complete = s >= 1 and e < len(frames) - 1
    if s < 1:
        notes.append("the film starts inside the motion")
    if e >= len(frames) - 1:
        notes.append("the film ends inside the motion")
    before, after = hints.get("rows_before") or {}, hints.get("rows_after") or {}

    movers, still, not_judged, resized = {}, {}, [], []
    for k in seen:
        if k in events:
            continue
        if k in start and k in end:
            y0, y1 = start[k][1], end[k][1]
            if is_row(k) and abs(end[k][3] - start[k][3]) * scale >= MOVER_PX:
                resized.append(k)
        elif is_row(k) and before.get(k) and after.get(k):
            y0, y1 = before[k][0], after[k][0]  # realized during the motion: its place from the row lists
        else:
            not_judged.append(k)
            continue
        if abs(y1 - y0) * scale >= MOVER_PX:
            movers[k] = (y0, y1 - y0)
        else:
            still[k] = y0
    if resized:
        notes.append("rows that changed height in this motion, judged on the same curve: " + ", ".join(resized[:8]))

    # The edge of a new or closing row that stays: the one away from the rows that move (y down: they move below it).
    def fixed_top(y):
        return not movers or statistics.median([y0 for y0, _ in movers.values()]) > y

    # (role, height at s, height at e, the edge that stays, whether it is the top edge); a resized row's edge is judged
    # with its y (it moves or stays like any row), only its height here.
    event_spec = {}
    for k in inserted:
        y, h = end[k][1], end[k][3]
        top = fixed_top(y)
        event_spec[k] = ("new", 0.0, h, y if top else y + h, top)
    for k in closed:
        y, h = start[k][1], start[k][3]
        top = fixed_top(y)
        event_spec[k] = ("closing", h, 0.0, y if top else y + h, top)
    for k in resized:
        event_spec[k] = ("resized", start[k][3], end[k][3], None, None)

    snap = (snap_mode or instant) and bool(inserted or closed)
    snap_result = (judge_instant(frames, s, e, inserted, closed, start, end, scale, tol) if instant else
                   judge_snap(frames, s, e, inserted, start, end, scale, tol) if snap and inserted and not closed else None)
    snap = snap_result is not None
    if snap:
        # Snap: the rows below are in their slots from the first motion frame (judged by judge_snap), the new row at full
        # height from its first frame: grow's curve and its height clause do not apply to the insert.
        for k in list(inserted) + (list(closed) if instant else []):
            event_spec.pop(k, None)
        movers, still = {}, {}

    # Progress per frame: least squares over the rows that move; with none shown, the new or closing row's height.
    progress = {}
    for i in window:
        views = frames[i]["views"]
        num = sum(d * (views[k][1] - y0) for k, (y0, d) in movers.items() if k in views)
        den = sum(d * d for k, (y0, d) in movers.items() if k in views)
        if den > 0:
            progress[i] = num / den
            continue
        for k, (role, h0, h1, _, _) in event_spec.items():
            if h1 != h0 and (k in views or role != "resized"):
                progress[i] = ((views[k][3] if k in views else 0.0) - h0) / (h1 - h0)
                break

    # A curve shows each refresh: more than half the motion inside one refresh, or from its start to its end with no
    # frame between, is a jump. A long first step after a stall that the curve then continues is a missed refresh
    # (counted below), not a jump.
    shown_p = [i for i in window if i in progress]
    progress_jumps = []
    for a, b in zip(shown_p, shown_p[1:]):
        pa, pb = progress[a], progress[b]
        if abs(pb - pa) <= MAX_PROGRESS_STEP:
            continue
        one_refresh = times is not None and b == a + 1 and times[b] - times[a] <= MISS_FACTOR * period
        whole = min(pa, pb) <= 1 - END_FRACTION and max(pa, pb) >= END_FRACTION
        if one_refresh or whole:
            progress_jumps.append({"frame": b, "from_p": round(pa, 4), "to_p": round(pb, 4),
                                   "why": "in one refresh" if one_refresh else "from start to end with no frame between"})

    row_errors, height_errors, spreads, jumps = {}, {}, {}, []
    worst_row, worst_height = {"frame": None, "key": None, "px": 0.0}, {"frame": None, "key": None, "px": 0.0}
    previous_error = {}
    for i in window:
        views, p = frames[i]["views"], progress.get(i)
        if p is None:
            continue
        own = [(views[k][1] - y0) / d for k, (y0, d) in movers.items() if k in views]
        if len(own) >= 2:
            spreads[i] = max(own) - min(own)
        expected = {k: y0 + p * d for k, (y0, d) in movers.items()}
        expected.update(still)
        for k, want in expected.items():
            if k not in views:
                previous_error.pop(k, None)
                continue
            err = abs(views[k][1] - want) * scale
            if err > worst_row["px"]:
                worst_row = {"frame": i, "key": k, "px": err}
            if err > tol and (i not in row_errors or err > row_errors[i]["px"]):
                row_errors[i] = {"frame": i, "key": k, "px": err}
            # Rebuilt row suspect (no ids): a row on the curve that leaves it in one frame.
            if identity is None and i - 1 in progress and k in frames[i - 1]["views"] and previous_error.get(k, tol + 1) <= tol:
                step = views[k][1] - frames[i - 1]["views"][k][1]
                want_step = (progress[i] - progress[i - 1]) * movers[k][1] if k in movers else 0.0
                limit = max(4.0, 0.25 * views[k][3] * scale)
                if abs(step - want_step) * scale > limit:
                    jumps.append({"frame": i, "key": k, "why": "jumped off the curve"})
            previous_error[k] = err
        for k, (role, h0, h1, edge, top) in event_spec.items():
            want_h = h0 + p * (h1 - h0)
            shown_h = views[k][3] if k in views else 0.0
            err = abs(shown_h - want_h) * scale
            if err > worst_height["px"]:
                worst_height = {"frame": i, "key": k, "px": err}
            if err > tol and (i not in height_errors or err > height_errors[i]["px"]):
                height_errors[i] = {"frame": i, "key": k, "px": err}
            # A zero-size view (made, not laid out) draws nothing: only its height is judged in that frame.
            if k in views and edge is not None and views[k][2] * scale >= MOVER_PX and views[k][3] * scale >= MOVER_PX:
                shown_edge = views[k][1] if top else views[k][1] + views[k][3]
                err = abs(shown_edge - edge) * scale
                if err > worst_row["px"]:
                    worst_row = {"frame": i, "key": k, "px": err}
                if err > tol and (i not in row_errors or err > row_errors[i]["px"]):
                    row_errors[i] = {"frame": i, "key": k, "px": err}

    # Same start frame: the first frame each row leaves its start (the new row: shows a height; the closing row: loses some).
    starts = {}
    for k, (y0, _) in movers.items():
        starts[k] = next((i for i in window if i > s and k in frames[i]["views"]
                          and abs(frames[i]["views"][k][1] - y0) > START_EPS_PT), None)
    for k, (_, h0, _, _, _) in event_spec.items():
        starts[k] = next((i for i in window if i > s and (frames[i]["views"][k][3] if k in frames[i]["views"] else 0.0)
                          != h0 and abs((frames[i]["views"][k][3] if k in frames[i]["views"] else 0.0) - h0) > START_EPS_PT), None)
    started = {k: f for k, f in starts.items() if f is not None}
    common = min(started.values()) if started else None
    late = sorted(({"key": k, "frame": f} for k, f in started.items() if f > common), key=lambda x: (x["frame"], x["key"]))

    # Missed refreshes: intervals inside the motion over 1.5 periods, across which a row moves (still frames between two
    # changes are part of the window, but a hitch there drops no frame of the motion).
    gaps, missed = [], 0
    if times is not None:
        for i in range(s + 1, e + 1):
            if not moves_across(frames[i - 1]["views"], frames[i]["views"], events, inserted if snap else ()):
                continue
            gap = times[i] - times[i - 1]
            if gap > MISS_FACTOR * period:
                count = max(1, int(round(gap / period)) - 1)
                missed += count
                gaps.append({"frame": i, "after": i - 1, "ms": round(gap * 1000, 3), "missed": count, "at_start": i == s + 1})

    # Presence, identity and opacity.
    rebuilt, flicker, reflow = [], [], []
    for k in seen:
        shown = [i for i in window if k in frames[i]["views"]]
        for a, b in zip(shown, shown[1:]):
            if b > a + 1:
                entry = {"frame": b, "from": a + 1, "key": k, "why": "left and came back"}
                (rebuilt if identity is None else flicker).append(entry)
        high, low = False, None
        for i in shown:
            opacity = frames[i]["views"][k][4]
            if opacity >= OPACITY_HIGH:
                if high and low is not None and identity is None:
                    rebuilt.append({"frame": i, "from": low, "key": k, "why": "opacity fell to 0 and came back"})
                high, low = True, None
            elif opacity <= OPACITY_LOW and high and low is None:
                low = i
        if k in events or not shown:
            continue
        ref = frames[shown[0]]["views"][k]
        for i in shown:
            box = frames[i]["views"][k]
            if abs(box[4] - ref[4]) > FLICKER_OPACITY:
                flicker.append({"frame": i, "key": k, "opacity": rounded(box[4])})
            if is_row(k) and (abs(box[0] - ref[0]) * scale > tol or abs(box[2] - ref[2]) * scale > tol):
                reflow.append({"frame": i, "key": k, "x": rounded(box[0]), "w": rounded(box[2])})
    if identity is not None:
        for k in seen:
            last_id = None
            for i in window:
                ids = frames[i]["ids"] or {}
                if k in ids:
                    if last_id is not None and ids[k] != last_id:
                        rebuilt.append({"frame": i, "key": k, "why": "view id changed"})
                    last_id = ids[k]
    rebuilt += jumps
    rebuilt.sort(key=lambda x: (x["frame"], x["key"]))
    flicker.sort(key=lambda x: (x["frame"], x["key"]))
    reflow.sort(key=lambda x: (x["frame"], x["key"]))

    selection = judge_selection(frames, window, scale, tol)

    kind = "+".join(name for name, rows in (("insert", inserted), ("remove", closed)) if rows) or "other"
    fails = list(snap_result["fails"]) if snap_result else []
    if missed:
        fails.append(f"{missed} missed refresh(es) in {len(gaps)} long interval(s), first at frame {gaps[0]['frame']}")
    if rebuilt:
        fails.append(f"rebuilt row view(s) at frame(s) {sorted({r['frame'] for r in rebuilt})[:10]}"
                     + ("" if identity is not None else " (suspects: no view ids)"))
    if flicker:
        fails.append(f"flicker at frame(s) {sorted({f['frame'] for f in flicker})[:10]}")
    if reflow:
        fails.append(f"re-wrap (x or width changed) from frame {reflow[0]['frame']}")
    if isinstance(selection, dict) and (selection["off_frames"] or selection["changes"] > 1 or selection["gaps"]):
        fails.append("the selection left its row" + (f" at frame(s) {selection['off_frames'][:10]}" if selection["off_frames"] else ""))
    if complete:
        if worst_row["px"] > tol:
            fails.append(f"row position error {worst_row['px']:.2f} px > {tol} px ({worst_row['key']} at frame {worst_row['frame']})")
        if worst_height["px"] > tol:
            fails.append(f"new/closing row height error {worst_height['px']:.2f} px > {tol} px "
                         f"({worst_height['key']} at frame {worst_height['frame']})")
        if progress_jumps:
            j = progress_jumps[0]
            fails.append(f"the rows jumped: progress {j['from_p']:.2f} -> {j['to_p']:.2f} in one frame at frame {j['frame']} "
                         f"(nothing grows or moves on a curve)")
        if late:
            first_key = min(k for k, f in started.items() if f == common)
            named = ", ".join("%s@%d" % (x["key"], x["frame"]) for x in late[:6])
            fails.append(f"rows did not start on the same frame: {first_key} at frame {common}, later {len(late)} row(s): {named}")
    verdict = "FAIL" if fails else ("INCOMPLETE" if not complete else "PASS")
    return {
        "start_frame": s, "end_frame": e, "kind": kind, "inserted": inserted, "closed": closed,
        "movers": len(movers), "still": len(still), "not_judged": not_judged[:LIST_CAP], "complete": complete,
        "resized": resized, "missed_refreshes": missed, "gaps": gaps[:LIST_CAP],
        "max_row_error_px": round(worst_row["px"], 4), "max_row_error": dict(worst_row, px=round(worst_row["px"], 4)),
        "row_error_frames": sorted(row_errors), "row_errors": [dict(v, px=round(v["px"], 3)) for _, v in sorted(row_errors.items())][:LIST_CAP],
        "max_height_error_px": round(worst_height["px"], 4),
        "max_height_error": dict(worst_height, px=round(worst_height["px"], 4)),
        "height_error_frames": sorted(height_errors),
        "height_errors": [dict(v, px=round(v["px"], 3)) for _, v in sorted(height_errors.items())][:LIST_CAP],
        "progress_spread_max": round(max(spreads.values(), default=0.0), 6),
        "progress_spread_frame": max(spreads, key=spreads.get) if spreads else None,
        "progress": {str(i): round(p, 6) for i, p in sorted(progress.items())},
        "progress_jumps": progress_jumps[:LIST_CAP],
        "start_frame_common": common, "late_starts": late[:LIST_CAP],
        "rebuilt": rebuilt[:LIST_CAP], "rebuilt_frames": sorted({r["frame"] for r in rebuilt}),
        "flicker": flicker[:LIST_CAP], "reflow": reflow[:LIST_CAP], "selection": selection,
        "verdict": verdict, "fails": fails, "notes": notes,
        "motion": "instant" if instant else ("snap" if snap else "grow"),
        **({k: v for k, v in snap_result.items() if k != "fails"} if snap_result else {}),
    }


def judge_snap(frames, s, e, inserted, start, end, scale, tol):
    """--motion snap: the insert of sidebar.insertMotion snap (the default since #28205). Every row shown at both ends of
    the window is, in every frame, at its start y or at its end y (within the tolerance), and once at its end y it stays:
    a frame between is a slide. The rows below the new row change slot in one frame (snap together). The new row draws
    (a laid-out view: a zero-size view, made and not laid out, draws nothing) at its slot at full height in every frame;
    it first draws in the frame the rows below make room: drawn before it covers a row that has not moved (overlap), drawn
    after it leaves a gap. Its opacity starts below OPACITY_HIGH (a fade, not a pop-in), rises each refresh until it
    reaches OPACITY_HIGH (an equal value is a held fade frame) and never falls by more than FADE_BACK_EPS."""
    window = range(s, e + 1)
    fails, slot_errors, height_errors, gap, overlap, fade_back, fade_held, split = [], [], [], [], [], [], [], []
    worst = {"frame": None, "key": None, "px": 0.0}
    worst_h = {"frame": None, "key": None, "px": 0.0}
    first_alpha = {}

    def drawn(views, k):
        return k in views and views[k][2] * scale >= MOVER_PX and views[k][3] * scale >= MOVER_PX

    rows = {r: (start[r][1], end[r][1]) for r in start if r in end and is_row(r) and r not in inserted}
    switch = {}
    for r, (y0, y1) in rows.items():
        moved = abs(y1 - y0) * scale > tol
        at_end = False
        for i in window:
            views = frames[i]["views"]
            if r not in views:
                continue
            y = views[r][1]
            off_start, off_end = abs(y - y0) * scale, abs(y - y1) * scale
            if moved and not at_end and off_end <= tol:
                at_end, switch[r] = True, i
            err = off_end if at_end else min(off_start, off_end)
            if err > worst["px"]:
                worst = {"frame": i, "key": r, "px": err}
            if err > tol:
                slot_errors.append({"frame": i, "key": r, "px": round(err, 3)})
    for k in inserted:
        box_end = end.get(k)
        if box_end is None:
            continue
        top, height = box_end[1], box_end[3]
        below = [r for r, (y0, y1) in rows.items() if y1 > top - 0.5 and r in switch]
        moments = sorted({switch[r] for r in below})
        if len(moments) > 1:
            split.extend(moments[1:])
        made_room = moments[0] if moments else None
        shown = [i for i in window if drawn(frames[i]["views"], k)]
        first = shown[0] if shown else None
        if made_room is not None:
            gap += [i for i in window if i >= made_room and (first is None or i < first)]
            if first is not None:
                overlap += [i for i in range(first, made_room)]
        previous = None
        for i in shown:
            box = frames[i]["views"][k]
            err_h, err_y = abs(box[3] - height) * scale, abs(box[1] - top) * scale
            if err_h > worst_h["px"]:
                worst_h = {"frame": i, "key": k, "px": err_h}
            if err_y > worst["px"]:
                worst = {"frame": i, "key": k, "px": err_y}
            if err_h > tol:
                height_errors.append({"frame": i, "key": k, "px": round(err_h, 3)})
            if err_y > tol:
                slot_errors.append({"frame": i, "key": k, "px": round(err_y, 3)})
            alpha = box[4]
            if previous is not None:
                if alpha < previous - FADE_BACK_EPS:
                    fade_back.append(i)
                elif previous < OPACITY_HIGH and abs(alpha - previous) <= CHANGE_EPS_PT:
                    fade_held.append(i)
            previous = alpha
        if first is not None:
            first_alpha[k] = frames[first]["views"][k][4]
    gap, overlap, split = sorted(set(gap)), sorted(set(overlap)), sorted(set(split))
    slid = sorted({x["key"] for x in slot_errors if x["key"] not in inserted})
    if slid:
        fails.append(f"snap: rows not in their slots (between their start and end slot, or back at the start: they slide): "
                     f"{', '.join(slid[:6])} (first at frame {min(x['frame'] for x in slot_errors if x['key'] in slid)})")
    if split:
        fails.append(f"snap: the rows below did not change slot in one frame (later ones at frame(s) {split[:10]})")
    if height_errors:
        fails.append(f"snap: the new row is not at full height (frames {[x['frame'] for x in height_errors][:10]})")
    if any(x["key"] in inserted for x in slot_errors):
        fails.append("snap: the new row is not at its slot")
    if gap:
        fails.append(f"snap: a gap where the new row goes (the rows below made room, the new row draws nothing) at frame(s) {gap[:10]}")
    if overlap:
        fails.append(f"snap: the new row overlaps a row that has not made room at frame(s) {overlap[:10]}")
    if fade_back:
        fails.append(f"snap: the new row's fade steps back at frame(s) {fade_back[:10]}")
    if fade_held:
        fails.append(f"snap: the new row's fade is held (the same opacity in two frames) at frame(s) {fade_held[:10]}")
    for k, alpha in first_alpha.items():
        if alpha >= OPACITY_HIGH:
            fails.append(f"snap: {k} does not fade in (opacity {alpha:.2f} in its first frame)")
    return {"fails": fails, "row_errors": slot_errors[:LIST_CAP], "row_error_frames": sorted({x["frame"] for x in slot_errors}),
            "max_row_error_px": round(worst["px"], 4), "max_row_error": dict(worst, px=round(worst["px"], 4)),
            "height_errors": height_errors[:LIST_CAP], "height_error_frames": sorted({x["frame"] for x in height_errors}),
            "max_height_error_px": round(worst_h["px"], 4), "max_height_error": dict(worst_h, px=round(worst_h["px"], 4)),
            "gap_frames": gap, "overlap_frames": overlap, "split_frames": split, "fade_back_frames": fade_back,
            "fade_held_frames": fade_held}


def judge_instant(frames, s, e, inserted, closed, start, end, scale, tol):
    """A press with no user intent (film mode noswitch: a script's change, focus false): the calm-movement rule shows it in
    one step (plans/cmux-next/sidebar-calm-movement.md; SidebarListView.showModelChange). Every row shown at both ends is at
    its start or its end slot in every frame and all rows that move change slot in the same frame; the new row draws at its
    slot at full height and opacity >= OPACITY_HIGH from its first frame, in that frame (no fade, no grow); the closing row
    is gone in that frame (no shrink, no fade)."""
    window = range(s, e + 1)
    fails, slot_errors, height_errors, faded = [], [], [], []
    worst = {"frame": None, "key": None, "px": 0.0}
    worst_h = {"frame": None, "key": None, "px": 0.0}
    rows = {r: (start[r][1], end[r][1]) for r in start if r in end and is_row(r) and r not in inserted}
    switch = {}
    for r, (y0, y1) in rows.items():
        moved = abs(y1 - y0) * scale > tol
        at_end = False
        for i in window:
            views = frames[i]["views"]
            if r not in views:
                continue
            off_start, off_end = abs(views[r][1] - y0) * scale, abs(views[r][1] - y1) * scale
            if moved and not at_end and off_end <= tol:
                at_end, switch[r] = True, i
            err = off_end if at_end else min(off_start, off_end)
            if err > worst["px"]:
                worst = {"frame": i, "key": r, "px": err}
            if err > tol:
                slot_errors.append({"frame": i, "key": r, "px": round(err, 3)})
    moments = set(switch.values())
    for k in inserted:
        box_end = end.get(k)
        shown = [i for i in window if k in frames[i]["views"] and frames[i]["views"][k][2] * scale >= MOVER_PX
                 and frames[i]["views"][k][3] * scale >= MOVER_PX]
        if box_end is None or not shown:
            continue
        moments.add(shown[0])
        for i in shown:
            box = frames[i]["views"][k]
            err_h, err_y = abs(box[3] - box_end[3]) * scale, abs(box[1] - box_end[1]) * scale
            worst_h = max(worst_h, {"frame": i, "key": k, "px": err_h}, key=lambda w: w["px"])
            worst = max(worst, {"frame": i, "key": k, "px": err_y}, key=lambda w: w["px"])
            if err_h > tol:
                height_errors.append({"frame": i, "key": k, "px": round(err_h, 3)})
            if err_y > tol:
                slot_errors.append({"frame": i, "key": k, "px": round(err_y, 3)})
            if box[4] < OPACITY_HIGH:
                faded.append(i)
    for k in closed:
        shown = [i for i in window if k in frames[i]["views"] and frames[i]["views"][k][3] * scale >= MOVER_PX]
        gone = next((i for i in window if i > s and (k not in frames[i]["views"] or frames[i]["views"][k][3] * scale < MOVER_PX)), None)
        if gone is not None:
            moments.add(gone)
        for i in shown:
            box = frames[i]["views"][k]
            if abs(box[3] - start[k][3]) * scale > tol:
                height_errors.append({"frame": i, "key": k, "px": round(abs(box[3] - start[k][3]) * scale, 3)})
            if box[4] < OPACITY_HIGH:
                faded.append(i)
    if len(moments) > 1:
        fails.append(f"instant: not in one step: the rows and the new or closing row change at frames {sorted(moments)[:10]}")
    slid = sorted({x["key"] for x in slot_errors})
    if slid:
        fails.append(f"instant: not in one step: rows between their start and end slot (a slide): {', '.join(slid[:6])}")
    if height_errors:
        fails.append(f"instant: not in one step: a new or closing row at partial height (frames {[x['frame'] for x in height_errors][:10]})")
    if faded:
        fails.append(f"instant: not in one step: a new or closing row fades (frames {sorted(set(faded))[:10]})")
    return {"fails": fails, "row_errors": slot_errors[:LIST_CAP], "row_error_frames": sorted({x["frame"] for x in slot_errors}),
            "max_row_error_px": round(worst["px"], 4), "max_row_error": dict(worst, px=round(worst["px"], 4)),
            "height_errors": height_errors[:LIST_CAP], "height_error_frames": sorted({x["frame"] for x in height_errors}),
            "max_height_error_px": round(worst_h["px"], 4), "max_height_error": dict(worst_h, px=round(worst_h["px"], 4)),
            "change_frames": sorted(moments), "faded_frames": sorted(set(faded))}


def judge_selection(frames, window, scale, tol):
    """The highlight keeps its offset to the row it selects; the selected key changes at most once and never blanks."""
    raws = [frames[i]["raw"] for i in window]
    if not any("selected" in r or "selection" in r for r in raws):
        return "not recorded"
    keys, off, reference = [], [], {}
    for i in window:
        raw, views = frames[i]["raw"], frames[i]["views"]
        box = raw.get("selection")
        key = raw.get("selected")
        if isinstance(box, dict):
            key, box = box.get("key", key), box.get("frame")
        keys.append(key)
        if not (isinstance(box, (list, tuple)) and len(box) >= 4 and all(is_num(v) for v in box[:4]) and key in views):
            continue
        row = views[key]
        offset = (box[0] - row[0], box[1] - row[1], box[2] - row[2], box[3] - row[3])
        ref = reference.setdefault(key, offset)
        if max(abs(a - b) for a, b in zip(offset, ref)) * scale > tol:
            off.append(i)
    shown = [k for k in keys if k is not None]
    changes = sum(1 for a, b in zip(shown, shown[1:]) if a != b)
    blanks = [window[j] for j, k in enumerate(keys) if k is None and any(keys[:j]) and any(keys[j + 1:])]
    return {"off_frames": off, "changes": changes, "gaps": blanks[:LIST_CAP]}


def judge_film(name, raw_frames, hints, opts):
    hints = dict(hints or {})
    if opts.inserted is not None or opts.closed is not None:
        hints["inserted"], hints["closed"] = set(opts.inserted or ()), set(opts.closed or ())
    frames = normalize(raw_frames)
    raws = [f["raw"] for f in frames]
    scale_values = sorted({float(r["scale"]) for r in raws if is_num(r.get("scale"))})
    if opts.scale:
        scale, scale_source = float(opts.scale), "flag"
    elif is_num(hints.get("scale")):
        scale, scale_source = float(hints["scale"]), "record"
    elif scale_values:
        scale, scale_source = scale_values[0], "record"
    else:
        scale, scale_source = 2.0, "assumed 2 (not recorded)"
    clock = next((c for c in ("target", "link", "t") if raws and all(is_num(r.get(c)) for r in raws)), None)
    times = [float(r[clock]) for r in raws] if clock else None
    refresh = [float(r["refresh"]) for r in raws if is_num(r.get("refresh")) and r["refresh"] > 0]
    intervals = [b - a for a, b in zip(times, times[1:]) if b > a] if times else []
    if opts.period_ms:
        period, period_source = opts.period_ms / 1000, "flag"
    elif refresh:
        period, period_source = statistics.median(refresh), "refresh"
    elif len(intervals) >= 2:
        period, period_source = statistics.median(intervals), "median interval"
    else:
        period, period_source = DEFAULT_PERIOD_S, "default 8.333 ms"
    identity = "ids" if frames and all(f["ids"] is not None for f in frames) else None
    result = {
        "film": name, "frames": len(frames), "clock": clock or "none", "period_ms": round(period * 1000, 4),
        "period_source": period_source, "hz": round(1 / period, 3), "scale": scale, "scale_source": scale_source,
        "tolerance_px": opts.tolerance_px, "identity": identity or NO_IDENTITY, "values": VALUES,
        "selection": "recorded" if any("selected" in r or "selection" in r for r in raws) else "not recorded",
    }
    snap_mode = getattr(opts, "motion", "grow") == "snap" and hints.get("mode") not in NO_INTENT_MODES
    judged = [judge_motion(frames, s, e, times, period, opts, scale, identity, hints)
              for s, e in windows(frames, hints, snap_mode)]
    contract = [m for m in judged if m["kind"] != "other"]
    invalid = []
    # 4. Rows the row lists name as new or closed must open or close in the film.
    opened = {k for m in contract for k in m["inserted"]}
    shut = {k for m in contract for k in m["closed"]}
    missing, outside = [], []
    shown_y = [v[1] for f in frames for k, v in f["views"].items() if is_row(k) and v[3] > 0]
    shown_end = [v[1] + v[3] for f in frames for k, v in f["views"].items() if is_row(k) and v[3] > 0]
    for k, place in [(k, (hints.get("rows_after") or {}).get(k)) for k in sorted(set(hints.get("inserted") or ()) - opened)] + \
            [(k, (hints.get("rows_before") or {}).get(k)) for k in sorted(set(hints.get("closed") or ()) - shut)]:
        inside = place is None or not shown_y or (min(shown_y) - 0.5 <= place[0] < max(shown_end) - 0.5)
        (missing if inside else outside).append(k)
    if len(frames) < 2:
        invalid.append("fewer than 2 frames")
    if times is None:
        invalid.append("frames have no times (t)")
    if opts.expect_hz and abs(result["hz"] - opts.expect_hz) > 0.05 * opts.expect_hz:
        invalid.append(f"the film runs at {result['hz']:.1f} Hz ({period_source}), not {opts.expect_hz:g} Hz "
                       f"(--period-ms or --expect-hz 0 to judge it anyway)")
    fails = [f"frames {m['start_frame']}-{m['end_frame']}: {f}" for m in contract for f in m["fails"]]
    fails += [f"{k} (new or closed in the row lists) never opens or closes in the film" for k in missing]
    if invalid:
        verdict = "INVALID"
    elif missing:
        verdict = "FAIL"
    elif not contract:
        verdict = "NO MOTION"
    else:
        verdict = min((m["verdict"] for m in contract), key=ORDER.index)
    result.update({
        "verdict": verdict, "fails": invalid + fails, "motions": judged,
        "missed_refreshes": sum(m["missed_refreshes"] for m in contract),
        "worst_gap_ms": max((g["ms"] for m in contract for g in m["gaps"]), default=0.0),
        "max_row_error_px": max((m["max_row_error_px"] for m in contract), default=0.0),
        "max_height_error_px": max((m["max_height_error_px"] for m in contract), default=0.0),
        "progress_spread_max": max((m["progress_spread_max"] for m in contract), default=0.0),
        "rebuilt_frames": sorted({f for m in contract for f in m["rebuilt_frames"]}),
        "selection_off_frames": sorted({f for m in contract if isinstance(m["selection"], dict) for f in m["selection"]["off_frames"]}),
    })
    notes = []
    if [m for m in judged if m["kind"] == "other"]:
        notes.append("motions with no row opening or closing are listed (kind other) and not judged")
    notes += [f"{k} (new or closed in the row lists) is outside the rows the film shows: not judged" for k in outside]
    if notes:
        result["notes"] = notes
    return result


def summary_line(report):
    films = report["films"]
    motions_ = [m for f in films for m in f["motions"] if m["kind"] != "other"]
    kinds = {k: sum(1 for m in motions_ if m["kind"] == k) for k in ("insert", "remove")}
    hz = sorted({f["hz"] for f in films})
    clocks = sorted({f["clock"] for f in films})
    identities = sorted({"ids" if f["identity"] == "ids" else "not available" for f in films})
    selections = sorted({f["selection"] for f in films})
    rebuilt = sum(len(f["rebuilt_frames"]) for f in films)
    return (f"sidebar row oracle: {report['verdict']}: motion {report.get('motion', 'grow')}: {len(films)} film(s), {len(motions_)} motion(s) "
            f"({kinds['insert']} insert, {kinds['remove']} remove); missed refreshes {report['missed_refreshes']} "
            f"(worst gap {report['worst_gap_ms']:.1f} ms; {'/'.join(f'{h:g}' for h in hz)} Hz by {'/'.join(clocks)}); "
            f"max row error {report['max_row_error_px']:.2f} px, new/closing row height error "
            f"{report['max_height_error_px']:.2f} px (tolerance {report['tolerance_px']:g} px, scale "
            f"{'/'.join(sorted({str(f['scale']) for f in films}))}); progress spread {report['progress_spread_max']:.4f}; "
            f"rebuilt rows {rebuilt} frame(s) (identity: {'/'.join(identities)}); selection {'/'.join(selections)}")


def build_report(path, opts):
    films = [judge_film(name, frames, hints, opts) for name, frames, hints in load_films(path)]
    verdict = min((f["verdict"] for f in films), key=ORDER.index) if films else "NO MOTION"
    return {
        "oracle": "sidebar_row_oracle", "contract": "cmux-ad m23 (STATUS 14191): sidebar row insert and remove",
        "input": path, "tolerance_px": opts.tolerance_px, "motion": getattr(opts, "motion", "grow"), "verdict": verdict, "films": films,
        "missed_refreshes": sum(f["missed_refreshes"] for f in films),
        "worst_gap_ms": max((f["worst_gap_ms"] for f in films), default=0.0),
        "max_row_error_px": max((f["max_row_error_px"] for f in films), default=0.0),
        "max_height_error_px": max((f["max_height_error_px"] for f in films), default=0.0),
        "progress_spread_max": max((f["progress_spread_max"] for f in films), default=0.0),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("film", help="a film JSON (samples.json, film-*.json, a motion report) or a folder of them")
    parser.add_argument("--json", dest="out", help="write the JSON report here (else print it before the summary line)")
    parser.add_argument("--scale", type=float, help="device px per point (default: the record's scale, else 2)")
    parser.add_argument("--tolerance-px", type=float, default=1.0, help="largest row error in device px (default 1)")
    parser.add_argument("--period-ms", type=float, help="display period (default: the probe's refresh, else the median interval)")
    parser.add_argument("--expect-hz", type=float, default=120.0, help="the display rate the film must have (0: any)")
    parser.add_argument("--inserted", action="append", help="the key of the new row (default: from the row lists or the film)")
    parser.add_argument("--closed", action="append", help="the key of the closing row (default: from the row lists or the film)")
    parser.add_argument("--motion", choices=MOTIONS, default="grow",
                        help="the sidebar.insertMotion value of the film: grow (default: the new row grows from 0, the m23 "
                             "clauses) or snap (the default motion of the app: the rows below in their slots at once, the new "
                             "row at full height while it fades in)")
    args = parser.parse_args(argv)
    if not os.path.exists(args.film):
        print(f"sidebar row oracle: no such file or folder: {args.film}", file=sys.stderr)
        return 2
    opts = Options(scale=args.scale, tolerance_px=args.tolerance_px, period_ms=args.period_ms,
                   expect_hz=args.expect_hz, inserted=args.inserted, closed=args.closed, motion=args.motion)
    report = build_report(args.film, opts)
    if not report["films"]:
        print(f"sidebar row oracle: no film in {args.film} (samples.json, film-*.json or a motion report)", file=sys.stderr)
        return 2
    text = json.dumps(report, indent=1)
    if args.out:
        with open(args.out, "w") as handle:
            handle.write(text + "\n")
    else:
        print(text)
    print(summary_line(report), flush=True)
    return {"PASS": 0, "FAIL": 1}.get(report["verdict"], 2)


if __name__ == "__main__":
    sys.exit(main())
