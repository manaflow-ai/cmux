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
    return out


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


def summarize(folder):
    """{"windows": [per window], "total": {...}} for a launch recording folder."""
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
    return {"windows": windows, "total": total}


def table(summary):
    """A Markdown table: one row per window and a total."""
    keys = ["first_paint_ms", "blank_first", "geometry_frames", "pixel_frames", "blank_frames", "layout_passes",
            "last_change_ms", "first_vs_final", "ended_by"]
    lines = ["| window | " + " | ".join(keys) + " |", "|" + "---|" * (len(keys) + 1)]
    for w in summary["windows"]:
        if "error" in w:
            lines.append(f"| {w['window']} | error: {w['error']} |")
            continue
        lines.append(f"| {w['window']} | " + " | ".join(str(w.get(k)) for k in keys) + " |")
    t = summary["total"]
    lines.append("| total | " + " | ".join(str(t.get(k, "")) for k in
                                           ["first_paint_ms", "blank_first", "geometry_frames", "pixel_frames",
                                            "blank_frames", "layout_passes", "last_change_ms"]) + " | | |")
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
