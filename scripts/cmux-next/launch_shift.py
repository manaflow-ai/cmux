#!/usr/bin/env python3
"""What moved after the first frame of a relaunch, read from the app's own launch recording.

Leo, 2026-11-04: "i feel like the restarted after nightly update does too many layout shifts/flicker renderings and
takes too long to reconnect acpmux or whatever". The budget (rulebook, three budgets): the first frame is the final
frame, and nothing moves after it first paints.

A Debug or bench app launched with `--record-launch DIR [--record-launch-seconds S]` (DebugWindowRecord) records every
window from its first composited frame, into `DIR/window-N/frames.json`: per frame its time, its time since the process
started (`processMs`), a 16x16 luminance grid (`cells`), the window's frame (`window`), how many views moved, resized,
appeared, showed, hid or went away since the frame before (`moved`, with the first few named in `movedViews`), and the
view layouts and window layout passes since the frame before (`viewLayouts`, `windowLayouts`). This module turns that
into numbers per window and for the whole launch:

  first_paint_ms      the window's first frame, ms after the process started
  blank_first         the first frame is flat (every cell within FLAT of the others): a blank window shown first
  geometry_frames     frames after the first in which any view moved, resized, appeared, showed, hid or went away,
                      or the window itself moved or resized
  pixel_frames        frames after the first in which at least PIXEL_SHARE of the cells changed by more than
                      PIXEL_DELTA (a region filling in, a flash, a fade; a caret or a ticking counter stays under it)
  blank_frames        frames after the first that are flat (a flash to one color)
  layout_passes       window layout passes after the first frame, the process's (every window's) while this one
                      records; the launch total is the largest of them, not their sum
                      (a lower bound: the passes before a window's first frame, and after its recording ends, are not counted)
  last_change_ms      when the last geometry or pixel change came, ms after the window's first frame (0: none)
  first_vs_final      the share of cells that differ between the first and the last frame (0: the first frame was final)
  views               the views that moved most often (name -> frames), from `movedViews`
  ended_by            `time`, or `closed` when the window closed while recorded (a launch window replaced by another)

The perceived numbers, the headline (Leo, 2026-11-24: "you know i favour percieved speed and percieved interactivity
over anything, so that's actually a measurement over anything. layout shifted things are bad tho, so those all need to
be prefetched/prerendered and all computed out properly."):

  settled_match_ms    ms from process start to the first frame that already looks done: it matches the settled frame
                      (the last one recorded; `settled` says whether nothing changed in the SETTLE_MS before it), and
                      after it no frame differs from the settled one by PIXEL_SHARE or more, no view moves, the window
                      keeps its frame and its alpha
  first_frame_is_final  that frame is the window's first
  shift_score         CLS-style: over the frames after the first, the sum of each moved view's (distance moved /
                      window diagonal) * (area of the union of its old and new rects / window area), from `movedRects`
                      (a window that moves or resizes counts as one view, the whole window); 0: nothing moved.
                      A recording with no `movedRects` (an older build): each frame with a geometry change counts
                      1/frames, and `shift_score_approx` is true
  alpha_changes       frames after the first in which the window's alpha changed (`alpha`; a fade in): a visual shift
                      of its own, reported apart; None when the recording has no `alpha`
  tti_ms, tti_mark    process start to the first input accepted, from the launch marks the recording carries
                      (`launchMarks`) or a harness passes: the earliest of TTI_MARKS, else `first_key_down`

and the launch's: the last settled_match_ms of the windows still open at the end (every window when all closed),
first_frame_is_final when it holds for each of those, the sum of the shift scores and alpha changes, and the tti.
`PERCEIVED settled_match_ms=... shift_score=... tti_ms=... first_frame_is_final=...` heads the output.

    python3 scripts/cmux-next/launch_shift.py DIR [--json]

prints one row per window and a total (`LAUNCH-SHIFT {json}` with --json). restore-journey.py --record-launch reads it
after each relaunch. Tests: python3 -I scripts/cmux-next/tests/test_launch_shift.py
"""
import collections
import glob
import json
import os
import re
import sys

FLAT = 4  # cells (0..255) within this of each other: one flat color
PIXEL_DELTA = 8  # a cell changed when its luminance moved by more than this (of 255)
PIXEL_SHARE = 0.03  # a frame changed when at least this share of its cells did (8 of 256)
ROW_NAME = re.compile(r"^(\S+) ")
SETTLE_MS = 500  # the last frame is the settled frame once nothing changed for this long before it
ALPHA_DELTA = 0.01  # the window's alpha changed when it moved by more than this
# The marks that say the app took a person's first input (LaunchInputMarks, HomeHostView, the agent pane): the
# earliest that came. `first_key_down` (the first key AppKit gave the app) is the fallback: when a key came, not when
# the app could take one.
TTI_MARKS = ("terminal_input_accepted", "window_usable", "agent_pane.input_echoed")
TTI_FALLBACK = "first_key_down"


def grid(text):
    """A frame's 16x16 cells from 512 hex digits; None when missing or malformed."""
    if not isinstance(text, str) or len(text) != 512:
        return None
    try:
        return [int(text[i:i + 2], 16) for i in range(0, 512, 2)]
    except ValueError:
        return None


def flat(cells):
    return cells is not None and max(cells) - min(cells) <= FLAT


def changed_share(a, b, delta=PIXEL_DELTA):
    if a is None or b is None:
        return 0.0
    return sum(1 for x, y in zip(a, b) if abs(x - y) > delta) / len(a)


def at(values, index, default=None):
    return values[index] if isinstance(values, list) and index < len(values) else default


def window(frames, name="window"):
    """The numbers of one window's frames.json (see the module doc)."""
    times = frames.get("times") or []
    n = len(times)
    out = {"window": name, "frames": n, "ended_by": frames.get("endedBy"), "first_paint_ms": None,
           "blank_first": None, "geometry_frames": 0, "pixel_frames": 0, "blank_frames": 0, "layout_passes": 0,
           "view_layouts": 0, "last_change_ms": 0, "first_vs_final": None, "window_moves": 0, "events": [], "views": {}}
    if not n:
        return out
    out["first_paint_ms"] = round(at(frames.get("processMs"), 0, 0) or 0)
    cells = [grid(c) for c in frames.get("cells") or []]
    has_cells = len(cells) == n and all(c is not None for c in cells)
    if has_cells:
        out["blank_first"] = flat(cells[0])
        out["first_vs_final"] = round(changed_share(cells[0], cells[-1]), 3)
    views = collections.Counter()
    rects = frames.get("window") or []
    for i in range(1, n):
        ms = round((times[i] - times[0]) * 1000)
        kinds = []
        moved = at(frames.get("moved"), i, 0) or 0
        window_moved = at(rects, i) is not None and at(rects, i) != at(rects, i - 1)
        if window_moved:
            out["window_moves"] += 1
        if moved or window_moved:
            out["geometry_frames"] += 1
            kinds.append("geometry")
            for line in at(frames.get("movedViews"), i, []) or []:
                match = ROW_NAME.match(line)
                if match:
                    views[match.group(1)] += 1
        share = changed_share(cells[i - 1], cells[i]) if has_cells else 0.0
        if share >= PIXEL_SHARE:
            out["pixel_frames"] += 1
            kinds.append("pixels")
        if has_cells and flat(cells[i]) and not flat(cells[i - 1]):
            out["blank_frames"] += 1
            kinds.append("blank")
        out["layout_passes"] += at(frames.get("windowLayouts"), i, 0) or 0
        out["view_layouts"] += at(frames.get("viewLayouts"), i, 0) or 0
        if kinds:
            out["last_change_ms"] = ms
            if len(out["events"]) < 40:
                event = {"ms": ms, "kinds": kinds, "share": round(share, 3), "moved": moved}
                if window_moved:
                    event["window"] = [at(rects, i - 1), at(rects, i)]
                lines = at(frames.get("movedViews"), i, []) or []
                if lines:
                    event["views"] = lines
                out["events"].append(event)
    out["views"] = dict(views.most_common(12))
    out.update(perceived(frames))
    return out


def _area(rect):
    return max(0.0, rect[2]) * max(0.0, rect[3])


def _union_area(a, b):
    ix = max(0.0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    return _area(a) + _area(b) - ix * iy


def move_distance(a, b):
    """How far a rect moved from `a` to `b`, in points: the larger of its origin's and its far corner's moves, so a
    view that only grew (a sidebar widened by 72 pt) moved 72."""
    origin = ((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2) ** 0.5
    corner = ((b[0] + b[2] - a[0] - a[2]) ** 2 + (b[1] + b[3] - a[1] - a[3]) ** 2) ** 0.5
    return max(origin, corner)


def shift_of(a, b, win):
    """One moved rect's CLS-style score in a window `win` ([x, y, w, h]): distance fraction * impact fraction, the
    impact capped at 1."""
    w, h = float(win[2]), float(win[3])
    if w <= 0 or h <= 0:
        return 0.0
    distance = move_distance(a, b) / (w * w + h * h) ** 0.5
    impact = min(1.0, _union_area(a, b) / (w * h))
    return distance * impact


def _rect(value):
    return [float(v) for v in value] if isinstance(value, list) and len(value) == 4 else None


def tti(marks):
    """(ms, mark) of the first input accepted, from launch marks {name: ms since process start}; (None, None)."""
    marks = marks or {}
    found = [(marks[m], m) for m in TTI_MARKS if isinstance(marks.get(m), (int, float))]
    if found:
        ms, mark = min(found)
        return round(ms), mark
    if isinstance(marks.get(TTI_FALLBACK), (int, float)):
        return round(marks[TTI_FALLBACK]), TTI_FALLBACK
    return None, None


def perceived(frames):
    """The perceived numbers of one window's frames.json (see the module doc)."""
    times = frames.get("times") or []
    n = len(times)
    out = {"settled_match_ms": None, "first_frame_is_final": None, "settled": None, "shift_score": 0.0,
           "shift_score_approx": False, "alpha_changes": None, "tti_ms": None, "tti_mark": None}
    out["tti_ms"], out["tti_mark"] = tti(frames.get("launchMarks"))
    if not n:
        return out
    process = frames.get("processMs") or []
    cells = [grid(c) for c in frames.get("cells") or []]
    has_cells = len(cells) == n and all(c is not None for c in cells)
    rects = frames.get("window") or []
    alpha = frames.get("alpha")
    has_alpha = isinstance(alpha, list) and len(alpha) == n
    moved = frames.get("moved") or []

    def geometry_changed(i):
        return bool(at(moved, i, 0)) or (at(rects, i) is not None and at(rects, i) != at(rects, i - 1))

    def alpha_changed(i):
        return has_alpha and abs((alpha[i] or 0) - (alpha[i - 1] or 0)) > ALPHA_DELTA

    def looks_final(i):
        if has_cells and changed_share(cells[i], cells[-1]) >= PIXEL_SHARE:
            return False
        if at(rects, i) != at(rects, n - 1):
            return False
        return not has_alpha or abs((alpha[i] or 0) - (alpha[-1] or 0)) <= ALPHA_DELTA

    # The first frame k from which every frame looks final and nothing moves after it.
    k = n - 1
    while k > 0 and looks_final(k - 1) and not geometry_changed(k) and not alpha_changed(k):
        k -= 1
    out["settled_match_ms"] = round(at(process, k, 0) or 0)
    out["first_frame_is_final"] = k == 0
    # Settled: no change of any kind in the SETTLE_MS before the last frame.
    last_change = 0
    for i in range(1, n):
        if (geometry_changed(i) or alpha_changed(i)
                or (has_cells and changed_share(cells[i - 1], cells[i]) >= PIXEL_SHARE)):
            last_change = i
    out["settled"] = last_change == 0 or (times[-1] - times[last_change]) * 1000 >= SETTLE_MS
    if has_alpha:
        out["alpha_changes"] = sum(1 for i in range(1, n) if alpha_changed(i))
    moved_rects = frames.get("movedRects")
    if isinstance(moved_rects, list) and len(moved_rects) == n:
        score = 0.0
        for i in range(1, n):
            win = _rect(at(rects, i)) or _rect(at(rects, i - 1))
            if win is None:
                continue
            before = _rect(at(rects, i - 1))
            if before is not None and before != win:
                # The window itself moved or resized: the whole window, in its own coordinates' frame.
                score += shift_of(before, win, before)
            for entry in moved_rects[i] or []:
                a, b = _rect((entry or {}).get("from")), _rect((entry or {}).get("to"))
                if a is not None and b is not None:
                    score += shift_of(a, b, win)
        out["shift_score"] = round(score, 4)
    else:
        out["shift_score"] = round(sum(1 for i in range(1, n) if geometry_changed(i)) / n, 4)
        out["shift_score_approx"] = True
    return out


def headline(numbers):
    """The PERCEIVED line: the headline of every launch harness that has a recording."""
    def text(v):
        return "null" if v is None else str(v).lower() if isinstance(v, bool) else str(v)
    keys = ("settled_match_ms", "shift_score", "tti_ms", "first_frame_is_final", "tti_mark", "shift_score_approx",
            "alpha_changes")
    return "PERCEIVED " + " ".join(f"{k}={text(numbers.get(k))}" for k in keys)


def read(folder):
    """Every window-N folder under `folder` (a launch recording), in window order: [(name, frames or error)]. A folder
    with no frames.json is an unfinished recording: an error, never left out."""
    found = []
    folders = glob.glob(os.path.join(folder, "window-*"))
    for folder_path in sorted(folders, key=lambda p: int(re.sub(r"\D", "", os.path.basename(p)) or 0)):
        name = os.path.basename(folder_path)
        path = os.path.join(folder_path, "frames.json")
        if not os.path.exists(path):
            found.append((name, {"error": "no frames.json (the recording did not finish)"}))
            continue
        try:
            with open(path) as f:
                data = json.load(f)
            found.append((name, data if isinstance(data, dict) else {"error": "not an object"}))
        except (OSError, ValueError) as error:
            found.append((name, {"error": str(error)}))
    return found


def recorded(folder):
    """Whether every window folder of the recording has written its frames.json (and there is at least one)."""
    folders = glob.glob(os.path.join(folder, "window-*"))
    return bool(folders) and all(os.path.exists(os.path.join(d, "frames.json")) for d in folders)


def summarize(folder, marks=None):
    """{"windows": [per window], "total": {...}} for a launch recording folder. `marks`: the launch marks a harness
    read itself (a marks pipe), for the tti when the recording carries none."""
    windows = []
    for name, data in read(folder):
        windows.append({"window": name, "error": data["error"]} if "error" in data else window(data, name))
    ok = [w for w in windows if "error" not in w]
    # A window that closed while recorded (the launch's own window, replaced by the restored ones) still counts:
    # it was on screen.
    total = {"windows": len(windows), "errors": len(windows) - len(ok)}
    for key in ("geometry_frames", "pixel_frames", "blank_frames", "window_moves"):
        total[key] = sum(w[key] for w in ok)
    # The layout counters are the process's (LayoutPassGuard), not the window's: each window's recording counts every
    # window's layouts while it records, so the launch's total is the longest recording's, never their sum.
    for key in ("layout_passes", "view_layouts"):
        total[key] = max((w[key] for w in ok), default=0)
    total["blank_first"] = sum(1 for w in ok if w["blank_first"])
    total["closed_while_recorded"] = sum(1 for w in ok if w.get("ended_by") == "closed")
    paints = [w["first_paint_ms"] for w in ok if w["first_paint_ms"] is not None]
    total["first_paint_ms"] = min(paints) if paints else None
    total["last_paint_ms"] = max(paints) if paints else None
    total["last_change_ms"] = max((w["last_change_ms"] for w in ok), default=0)
    views = collections.Counter()
    for w in ok:
        views.update(w["views"])
    total["views"] = dict(views.most_common(12))
    # Perceived: the launch looks done when every window still open does (a window the launch closed was replaced).
    open_windows = [w for w in ok if w.get("ended_by") != "closed"] or ok
    settled = [w["settled_match_ms"] for w in open_windows if w.get("settled_match_ms") is not None]
    total["settled_match_ms"] = max(settled) if settled else None
    finals = [w["first_frame_is_final"] for w in open_windows if w.get("first_frame_is_final") is not None]
    total["first_frame_is_final"] = all(finals) if finals else None
    total["settled"] = all(w.get("settled") for w in open_windows) if open_windows else None
    total["shift_score"] = round(sum(w.get("shift_score") or 0 for w in ok), 4)
    total["shift_score_approx"] = any(w.get("shift_score_approx") for w in ok)
    alphas = [w["alpha_changes"] for w in ok if w.get("alpha_changes") is not None]
    total["alpha_changes"] = sum(alphas) if alphas else None
    merged = {}
    for _, data in read(folder):
        for name, ms in ((data.get("launchMarks") or {}) if "error" not in data else {}).items():
            merged.setdefault(name, ms)
    merged.update({k: v for k, v in (marks or {}).items() if k not in merged})
    total["tti_ms"], total["tti_mark"] = tti(merged)
    return {"windows": windows, "total": total}


def table(summary):
    """A Markdown table: one row per window and a total."""
    keys = ["settled_match_ms", "first_frame_is_final", "shift_score", "alpha_changes", "first_paint_ms",
            "blank_first", "geometry_frames", "pixel_frames", "blank_frames", "layout_passes", "last_change_ms",
            "first_vs_final", "ended_by"]
    lines = [headline(summary["total"]), "", "| window | " + " | ".join(keys) + " |", "|" + "---|" * (len(keys) + 1)]
    for w in summary["windows"]:
        if "error" in w:
            lines.append(f"| {w['window']} | error: {w['error']} |")
            continue
        lines.append(f"| {w['window']} | " + " | ".join(str(w.get(k)) for k in keys) + " |")
    t = summary["total"]
    lines.append("| total | " + " | ".join(str(t.get(k, "")) for k in keys[:-2]) + " | | |")
    if t.get("views"):
        lines.append("")
        lines.append("Views that moved after the first frame (frames): " +
                     ", ".join(f"{k} {v}" for k, v in t["views"].items()))
    return "\n".join(lines)


def main(argv):
    if not argv or argv[0].startswith("-"):
        print(__doc__)
        return 2
    summary = summarize(argv[0])
    if "--json" in argv:
        print("LAUNCH-SHIFT " + json.dumps(summary["total"]))
    print(table(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
