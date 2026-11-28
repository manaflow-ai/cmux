"""The judging half of the tab switch harness (tab_switch_frames.py): pure functions over recorded frames, so a test
runs them on any host.

Leo, 2026-11-15: a tab switch should be instant even under load, and the tab or its animation should know where it
goes. So each switch is judged on the frames the screen showed (scripts/measure/tab-switch-frames/recorder.swift: the
window's region, 8-bit gray, one record per frame the picture changed, display-time stamped), against the frame the
switch must end on:

  to_content_ms   from the switch's mark to the first frame of the run that equals the expected end frame to the end of
                  the recording (the returning tab's last frame before it was left; for a new tab or a close, the
                  settled frame). None when the recording never reached it.
  blank_frames    display frames after the mark, before the end frame, where the content area is flat and is neither
                  the frame before the switch nor the end frame
  wrong_frames    display frames after the mark, before the end frame, that are neither the old tab, nor blank, nor the
                  end frame: an empty or centered composer before the transcript, text first and the view later
  shift_px        the most the content moved (points, vertically) between the first frame that shows the new tab's
                  content and the end frame, when that frame is the end frame shifted (the transcript and the composer
                  are judged apart: the top 80 % and the bottom 20 % of the content area)
  insert_ok       new tab and close: the tab strip first changes where it ends changing (the leftmost and rightmost
                  changed columns of the first changed strip frame are within one tab's slack of the final ones)
  anim_end_ok     new tab and close: the strip moves toward its final layout and never rests away from it first (no
                  frame where it held still for two display frames off its final layout, then moved on: an animation
                  that ended in the wrong place and snapped)

A frame lasts until the next one, so a picture that stayed for three display refreshes counts three frames.
Comparisons quantize gray to 32 levels and count the share of pixels that differ; two pictures are the same when at
most TOLERANCE of the area differs (a blinking terminal cursor is under it).

Budgets (BUDGETS): the returning tab shows its last frame within one display frame, 0 blank frames, 0 wrong frames,
0 px shift, the insert and the animation end right. Report schema: report() ("tab-switch/v1").
"""
from __future__ import annotations

import math
import struct
import zlib

TOLERANCE = 0.002
FLAT_SHARE = 0.985
SHIFT_MAX_POINTS = 120
SHIFT_MATCH = 0.01
# A frame's display time and the mark come from one clock, but the frame that the switch's own commit makes can land
# a little after a display frame boundary; 1 ms of slack on the one-frame budget.
FRAME_SLACK_MS = 1.0
QUANT = bytes(v >> 3 for v in range(256))
SCHEMA = "tab-switch/v1"
SCENARIOS = ("chat-long-return", "terminal-return", "chromium-return", "new-tab", "close-tab")
# Beside the defaults (scenarios=all): a WebKit page's return, workspaces opened, switched and closed, and rapid
# sequences whose animations retarget mid-flight (tab_switch_frames.py's docstring says what each drives).
MORE_SCENARIOS = ("webkit-return", "new-workspace", "switch-workspace", "close-workspace", "rapid-open-5",
                  "rapid-close-3", "open-while-close", "browser-split")
ALL_SCENARIOS = SCENARIOS + MORE_SCENARIOS
LOADS = ("idle", "cpu", "agents")


def read_segment(path, w, h):
    """[(seconds, gray bytes)] of one recorder segment file."""
    size = 8 + w * h
    frames = []
    with open(path, "rb") as handle:
        data = handle.read()
    for offset in range(0, len(data) - size + 1, size):
        (t,) = struct.unpack_from("<d", data, offset)
        frames.append((t, data[offset + 8:offset + size]))
    frames.sort(key=lambda f: f[0])
    return frames


def crop(frame, w, rect):
    """The bytes of `rect` (x0, y0, x1, y1, pixels, end exclusive) of a w-wide gray frame, quantized."""
    x0, y0, x1, y1 = rect
    return b"".join(frame[y * w + x0:y * w + x1] for y in range(y0, y1)).translate(QUANT)


def diff_share(a, b):
    """The share of pixels that differ between two quantized crops of one size (1.0 when the sizes differ)."""
    n = len(a)
    if n == 0 or n != len(b):
        return 1.0
    x = int.from_bytes(a, "little") ^ int.from_bytes(b, "little")
    return (n - x.to_bytes(n, "little").count(0)) / n


def flatness(a):
    """The share of the most common value in a quantized crop."""
    if not a:
        return 1.0
    return max(a.count(bytes([v])) for v in set(a[:: max(1, len(a) // 512)])) / len(a)


def is_blank(a, before, end, tolerance=TOLERANCE):
    return flatness(a) >= FLAT_SHARE and diff_share(a, before) > tolerance and diff_share(a, end) > tolerance


def vertical_shift(a, b, row, max_rows):
    """The vertical offset in rows (a's content is b's moved down by dy) that makes the crops match best, and the
    share that differs there; (0, share at 0) when no offset matches better."""
    rows = len(a) // row
    best = (0, diff_share(a, b))
    for dy in range(-max_rows, max_rows + 1):
        if dy == 0 or abs(dy) >= rows - 4:
            continue
        if dy > 0:
            share = diff_share(a[dy * row:], b[:len(b) - dy * row])
        else:
            share = diff_share(a[:len(a) + dy * row], b[-dy * row:])
        if share < best[1] - TOLERANCE:
            best = (dy, share)
    return best


def frames_covered(t, t_next, frame_ms):
    """Display frames a picture shown from t to t_next (seconds) covered: at least one."""
    return max(1, int(math.ceil(((t_next - t) * 1000 - FRAME_SLACK_MS) / frame_ms)))


def judge_switch(frames, mark, w, content, frame_ms, reference=None, strip=None, px_per_point=1.0, tolerance=TOLERANCE):
    """One switch from a segment's frames [(seconds, gray)] and its mark (seconds): the switch record (module doc).
    `content` and `strip` are pixel rects; `reference` is the expected end frame (full gray), else the last frame."""
    out = {"to_content_ms": None, "display_frame_ms": round(frame_ms, 3), "blank_frames": 0, "wrong_frames": 0,
           "shift_px": 0, "insert_ok": None, "anim_end_ok": None}
    if not frames:
        out["error"] = "no frames"
        return out
    before_frames = [f for f in frames if f[0] <= mark]
    after = [f for f in frames if f[0] > mark]
    before = (before_frames or frames[:1])[-1]
    end_full = reference if reference is not None else frames[-1][1]
    cb, ce = crop(before[1], w, content), crop(end_full, w, content)
    last = crop(frames[-1][1], w, content)
    out["end_matches_reference"] = diff_share(last, ce) <= tolerance
    out["frames_after"] = len(after)
    if not after:
        out["error"] = "no frame after the switch"
        return out
    crops = [crop(f[1], w, content) for f in after]
    # The run that equals the end frame to the end of the recording.
    settled = len(after)
    while settled > 0 and diff_share(crops[settled - 1], ce) <= tolerance:
        settled -= 1
    if settled < len(after):
        out["to_content_ms"] = round((after[settled][0] - mark) * 1000, 2)
    times = [f[0] for f in after]
    ends = times[1:] + [times[-1] + frame_ms / 1000]
    first_content = None
    for i in range(settled):
        n = frames_covered(times[i], ends[i], frame_ms)
        same_before = diff_share(crops[i], cb) <= tolerance
        if same_before:
            continue
        if is_blank(crops[i], cb, ce, tolerance):
            out["blank_frames"] += n
            out.setdefault("first_blank_frame", i)
            continue
        out["wrong_frames"] += n
        if first_content is None:
            first_content = i
    out["first_content_frame"] = first_content
    # Layout shift: the first content frame against the end frame, transcript and composer apart.
    if first_content is not None:
        x0, y0, x1, y1 = content
        split = y0 + int((y1 - y0) * 0.8)
        moved = 0
        for band in ((x0, y0, x1, split), (x0, split, x1, y1)):
            a = crop(after[first_content][1], w, band)
            b = crop(end_full, w, band)
            dy, share = vertical_shift(a, b, band[2] - band[0], int(SHIFT_MAX_POINTS * px_per_point))
            if dy and share <= SHIFT_MATCH:
                moved = max(moved, abs(dy) / px_per_point)
        out["shift_px"] = round(moved, 1)
    if strip is not None:
        out.update(judge_strip(frames, mark, w, strip, frame_ms, px_per_point, tolerance))
    return out


def changed_columns(a, b, width, axis="x"):
    """The columns (axis "x") or rows (axis "y") where two quantized strip crops of row width `width` differ."""
    rows = len(a) // width if width else 0
    columns = set()
    for y in range(rows):
        ra, rb = a[y * width:(y + 1) * width], b[y * width:(y + 1) * width]
        if ra == rb:
            continue
        if axis == "y":
            columns.add(y)
        else:
            columns.update(x for x in range(width) if ra[x] != rb[x])
    return columns


def judge_strip(frames, mark, w, strip, frame_ms, px_per_point=1.0, tolerance=TOLERANCE, tab_points=60, axis="x"):
    """insert_ok and anim_end_ok of a new tab or a close (module doc), from the tab strip's pixels; axis "y" judges a
    vertical list (the sidebar's workspace rows) by its changed rows, with `tab_points` one row's slack. Also the frame
    indexes after the mark where the strip first moved (strip_first_frame) and where its animation went wrong
    (anim_bad_frame, anim_bad_why)."""
    width = strip[2] - strip[0]
    before_frames = [f for f in frames if f[0] <= mark] or frames[:1]
    after = [f for f in frames if f[0] > mark]
    out = {"insert_ok": None, "anim_end_ok": None}
    if not after or width <= 0:
        out["strip_note"] = "no strip frames"
        return out
    sb = crop(before_frames[-1][1], w, strip)
    crops = [crop(f[1], w, strip) for f in after]
    sf = crops[-1]
    final_cols = changed_columns(sb, sf, width, axis)
    if diff_share(sb, sf) <= tolerance or not final_cols:
        out["strip_note"] = "the strip did not change"
        return out
    first_index = next((i for i, c in enumerate(crops) if diff_share(c, sb) > tolerance), None)
    first = crops[first_index] if first_index is not None else None
    out["strip_first_frame"] = first_index
    first_cols = changed_columns(sb, first, width, axis) if first is not None else set()
    slack = tab_points * px_per_point
    out["insert_ok"] = bool(first_cols) and abs(min(first_cols) - min(final_cols)) <= slack \
        and max(first_cols) <= max(final_cols) + slack
    out["strip_first_cols"] = [min(first_cols), max(first_cols)] if first_cols else None
    out["strip_final_cols"] = [min(final_cols), max(final_cols)]
    # Distance to the final strip per frame; a rest away from it (two display frames still) followed by more motion.
    distances = [diff_share(c, sf) for c in crops]
    # Frames come only when the picture changes, so a picture held two display frames or more is a rest; one before
    # the strip first moved is the switch's lag (to_content_ms), not a rest.
    times = [f[0] for f in after]
    moved = next((i for i, c in enumerate(crops) if diff_share(c, sb) > tolerance), len(crops))
    rest = next((i + 1 for i in range(moved, len(crops) - 1)
                 if (times[i + 1] - times[i]) * 1000 >= 2 * frame_ms - FRAME_SLACK_MS and distances[i] > tolerance), None)
    away = next((i for i in range(moved + 1, len(distances)) if distances[i] > distances[i - 1] + 0.02), None)
    rested_off, went_away = rest is not None, away is not None
    out["anim_end_ok"] = not rested_off and not went_away
    if not out["anim_end_ok"]:
        bad = min(i for i in (rest, away) if i is not None)
        out["anim_bad_frame"] = bad
        out["anim_bad_why"] = ("moved away from its final layout" if bad == away
                               else "rested off its final layout, then moved on")
    out["strip_distances"] = [round(d, 4) for d in distances[:40]]
    return out


BUDGETS = {
    "to_content_ms": "the returning tab shows its last frame within one display frame",
    "blank_frames": "0 blank frames",
    "wrong_frames": "0 wrong frames",
    "shift_px": "0 px shift",
    "insert_ok": "the new tab appears where the strip ends",
    "anim_end_ok": "the animation ends on the strip's final layout",
}


def budget_fails(switch, label):
    """The budget failures of one switch, as strings naming the switch."""
    fails = []
    if switch.get("error"):
        fails.append(f"{label}: {switch['error']}")
        return fails
    if switch.get("gate") == "blank-only":
        # browser-split: the pane's layout moves by design, so only an empty frame in the new pane fails.
        if (switch.get("blank_frames") or 0) > 0:
            fails.append(f"{label}: {switch['blank_frames']} blank frames in the new pane")
        if switch.get("to_content_ms") is None:
            fails.append(f"{label}: the new pane never showed its page")
        return fails
    to, frame = switch.get("to_content_ms"), switch.get("display_frame_ms") or 0
    if to is None:
        fails.append(f"{label}: never showed the expected content")
    elif to > frame + FRAME_SLACK_MS:
        fails.append(f"{label}: content at {to:.1f} ms, budget one display frame ({frame:.1f} ms)")
    for key in ("blank_frames", "wrong_frames"):
        if (switch.get(key) or 0) > 0:
            fails.append(f"{label}: {switch[key]} {key.replace('_', ' ')}")
    if (switch.get("shift_px") or 0) > 0:
        fails.append(f"{label}: content moved {switch['shift_px']} pt after first paint")
    for key in ("insert_ok", "anim_end_ok"):
        if switch.get(key) is False:
            fails.append(f"{label}: {BUDGETS[key]}: no")
    return fails


def scenario_row(name, load, switches, notes=None):
    """A scenario x load row. A round recorded with another process's window over the app ("foreign_window", set by
    tab_switch_foreign) is not judged: it moves to row["excluded"], so no stat, budget or table cell counts it."""
    excluded = [s for s in switches if s.get("foreign_window")]
    switches = [s for s in switches if not s.get("foreign_window")]
    fails = []
    for index, switch in enumerate(switches):
        fails += budget_fails(switch, f"{name}/{load} switch {index + 1}")
    if not switches:
        fails.append(f"{name}/{load}: no switch measured" + (f" ({notes})" if notes else "")
                     + (f" ({len(excluded)} excluded: foreign window)" if excluded else ""))
    row = {"name": name, "load": load, "switches": switches, "budget_fail": fails}
    if excluded:
        row["excluded"] = [{k: s.get(k) for k in ("label", "foreign_window", "windows")} for s in excluded]
    if notes:
        row["notes"] = notes
    return row


def report(build, display_hz, scenarios, extra=None):
    """The tab-switch/v1 report (the PR gate reads it)."""
    out = {"schema": SCHEMA, "build": build, "display_hz": display_hz, "scenarios": scenarios,
           "pass": bool(scenarios) and all(not s["budget_fail"] for s in scenarios)}
    if extra:
        out.update(extra)
    return out


def summary(row):
    """One line per scenario row: medians and worst values."""
    s = row["switches"]
    tos = sorted(x["to_content_ms"] for x in s if x.get("to_content_ms") is not None)
    median = tos[len(tos) // 2] if tos else None
    return {"name": row["name"], "load": row["load"], "switches": len(s),
            "to_content_ms_p50": median, "to_content_ms_max": tos[-1] if tos else None,
            "never": sum(1 for x in s if x.get("to_content_ms") is None),
            "blank_frames_max": max((x.get("blank_frames") or 0 for x in s), default=0),
            "wrong_frames_max": max((x.get("wrong_frames") or 0 for x in s), default=0),
            "shift_px_max": max((x.get("shift_px") or 0 for x in s), default=0),
            "insert_bad": sum(1 for x in s if x.get("insert_ok") is False),
            "anim_bad": sum(1 for x in s if x.get("anim_end_ok") is False),
            "fails": len(row["budget_fail"])}


def png_gray(width, height, pixels):
    """An 8-bit gray PNG of `pixels` (bytes, row by row)."""
    raw = b"".join(b"\x00" + pixels[y * width:(y + 1) * width] for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def contact_sheet(frames, mark, w, h, columns=6, limit=24, reference=None):
    """A PNG of the frame before the mark and the frames after it (at most `limit`), left to right, top to bottom,
    with the expected end frame last when given; 4 px gaps. Returns (png bytes, [ms of each tile])."""
    before = [f for f in frames if f[0] <= mark][-1:]
    after = [f for f in frames if f[0] > mark][:limit]
    tiles = [(round((t - mark) * 1000, 1), g) for t, g in before + after]
    if reference is not None:
        tiles.append(("end", reference))
    if not tiles:
        return None, []
    gap = 4
    cols = min(columns, len(tiles))
    rows = (len(tiles) + cols - 1) // cols
    sw, sh = cols * w + (cols - 1) * gap, rows * h + (rows - 1) * gap
    sheet = bytearray(b"\x80" * (sw * sh))
    for index, (_ms, gray) in enumerate(tiles):
        ox, oy = (index % cols) * (w + gap), (index // cols) * (h + gap)
        for y in range(h):
            sheet[(oy + y) * sw + ox:(oy + y) * sw + ox + w] = gray[y * w:(y + 1) * w]
    return png_gray(sw, sh, bytes(sheet)), [ms for ms, _ in tiles]


def content_rect(a, b, w, h, min_share=0.5):
    """The content area from two full frames of two different tabs (a terminal and a full-color page): the rows and
    columns where most pixels differ. None when they barely differ (the capture shows no page content)."""
    qa, qb = a.translate(QUANT), b.translate(QUANT)
    rows = []
    for y in range(h):
        ra, rb = qa[y * w:(y + 1) * w], qb[y * w:(y + 1) * w]
        rows.append(diff_share(ra, rb))
    ys = [y for y, s in enumerate(rows) if s >= min_share]
    if len(ys) < h // 8:
        return None
    y0, y1 = ys[0], ys[-1] + 1
    cols = []
    for x in range(w):
        col_a = bytes(qa[y * w + x] for y in range(y0, y1, 2))
        col_b = bytes(qb[y * w + x] for y in range(y0, y1, 2))
        cols.append(diff_share(col_a, col_b))
    xs = [x for x, s in enumerate(cols) if s >= min_share]
    if len(xs) < w // 8:
        return None
    return (xs[0], y0, xs[-1] + 1, y1)


def sidebar_rect(content, px_per_point, h, gap_points=6, min_points=60):
    """The sidebar: the band left of the content area (and its strip), full height, when it is at least `min_points`
    wide; None otherwise (a hidden sidebar)."""
    x1 = content[0] - int(gap_points * px_per_point)
    return (0, 0, x1, h) if x1 >= min_points * px_per_point else None


def strip_rect(content, px_per_point, h, strip_points=44):
    """The pane's tab strip: the band of `strip_points` above the content area, as wide as it."""
    x0, y0, x1, _y1 = content
    top = max(0, y0 - int(strip_points * px_per_point))
    return (x0, top, x1, y0) if y0 - top >= 4 else None
