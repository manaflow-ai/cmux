"""Settled time and the oddity log of the tab switch harness (tab_switch_frames.py): pure functions over recorded
frames, so a test runs them on any host.

Leo, 2026-11-16: "opening closing tabs and workspaces idk why we didn't measure settled states before but like /
testing it under actual extreme load is the point and seeing what oddities arise is meaningful".

tab_switch_judge.py answers when the content was right. This module answers when the whole window stopped moving, and
lists everything odd on the way there:

  settled_ms           from the mark to the first frame of the window's final picture, when that picture then held for
                       QUIET_MS (300 ms: no layout shift, no content change, no running animation) to the end of the
                       recording. None when the window was still changing QUIET_MS before the recording ended
                       (`settle_note` says which), an oddity of its own (never-settled).
  changed_after_first  frames with a change after the first changed frame: 0 is a single-frame action
  first_change_ms      the first frame after the mark that changed anything in the window

What counts as a change: the window is cut into TILE x TILE pixel tiles; a tile changed when more than
TILE_CHANGE_SHARE of its pixels differ (quantized gray, as the judge's). Two things are left out:
  ambient tiles  tiles that already changed in the half second before the action (a streaming chat in view, a
                 sidebar spinner, a printing terminal): the load's own motion, not the action's. ambient_share says
                 how much of the window that was. A change of more than half the window there is the tail of the
                 action before, not the load: it stays in.
  blinks         a change of at most BLINK_TILES tiles back to a picture each of them already showed since the mark
                 (a terminal cursor blinking), or of at most OSCILLATION_TILES tiles that each went back to an earlier
                 picture OSCILLATION_RETURNS times (a cursor and a caret blinking together).

Oddity kinds (oddities()), each with the frame index after the mark it is first seen at:
  placement             the tab strip (or the sidebar, for a workspace) first changed away from where it ends changing:
                        a tab inserted in one place, then moved to its slot
  retarget              an animation that headed to one target, then reversed or snapped: the strip moved away from its
                        final layout, or rested off it for two display frames and then moved on
  flicker               the content area showed a picture, changed, then went back to that picture (the old tab, a
                        blank, the end picture lost and found again)
  blank                 blank content frames before the end picture
  layout-after-content  the content was right, and the window kept changing for more than two display frames after
  shift                 the content moved after its first paint (the judge's shift_px)
  late-change           the window held still for QUIET_MS, then changed again
  never-settled         the window never held still for QUIET_MS before the recording ended
"""
from __future__ import annotations

import re

import tab_switch_judge as judge

QUIET_MS = 300.0
TILE = 16
TILE_CHANGE_SHARE = 0.02
BLINK_TILES = 2
OSCILLATION_RETURNS = 2
OSCILLATION_TILES = 12
OSCILLATION_STATES = 3
OSCILLATION_MATCH_SHARE = 0.15
AMBIENT_S = 0.5
AMBIENT_MAX_SHARE = 0.5
STATES_PER_TILE = 8
ODDITY_KINDS = ("placement", "retarget", "flicker", "blank", "layout-after-content", "shift", "late-change",
                "never-settled")
_NONZERO = re.compile(b"[^\x00]")
# Two coarse gray grids, the second offset by half a step: a pixel changed when it moved a step in both, so a change of
# less than 8 gray levels never counts. The recording's compression redraws a still window with +-1 to 6 levels of
# noise, which flipped the judge's 8-level grid and read as late changes seconds after an action (a CI mini, 2026-11-18).
COARSE = bytes(v >> 4 for v in range(256))
COARSE_SHIFTED = bytes(min(255, v + 8) >> 4 for v in range(256))


def coarse(g):
    """`g`'s two coarse grids (COARSE, COARSE_SHIFTED)."""
    return g.translate(COARSE), g.translate(COARSE_SHIFTED)


_ONE = bytes([0] + [1] * 255)


def changed_both(a, b, w, h, tile=TILE):
    """The tiles where enough pixels changed in both coarse grids between coarse pairs `a` and `b` (module doc)."""
    if a[0] == b[0] or a[1] == b[1] or len(a[0]) != len(b[0]):
        return changed_tiles(a[0], b[0], w, h, tile) if len(a[0]) != len(b[0]) else set()
    n = len(a[0])

    def moved(x, y):  # 1 where the pixel moved a step in this grid
        return int.from_bytes((int.from_bytes(x, "little") ^ int.from_bytes(y, "little")).to_bytes(n, "little")
                              .translate(_ONE), "little")

    both = (moved(a[0], b[0]) & moved(a[1], b[1])).to_bytes(n, "little")
    return changed_tiles(both, bytes(n), w, h, tile)


def tiles_of(w, h, tile=TILE):
    """The tile grid of a w x h frame: (columns, rows)."""
    return (w + tile - 1) // tile, (h + tile - 1) // tile


def changed_tiles(a, b, w, h, tile=TILE, share=TILE_CHANGE_SHARE):
    """The tiles (index row * columns + column) where quantized frames a and b differ in more than `share` of the
    tile's pixels."""
    if a == b:
        return set()
    n = len(a)
    if n != len(b):
        cols, rows = tiles_of(w, h, tile)
        return set(range(cols * rows))
    x = (int.from_bytes(a, "little") ^ int.from_bytes(b, "little")).to_bytes(n, "little")
    cols, _rows = tiles_of(w, h, tile)
    counts = {}
    for y in range(h):
        row = x[y * w:(y + 1) * w]
        if not row.strip(b"\x00"):
            continue
        base = (y // tile) * cols
        for m in _NONZERO.finditer(row):
            k = base + m.start() // tile
            counts[k] = counts.get(k, 0) + 1
    out = set()
    for k, count in counts.items():
        tx, ty = k % cols, k // cols
        tw = min(tile, w - tx * tile)
        th = min(tile, h - ty * tile)
        if count > share * tw * th:
            out.add(k)
    return out


def tile_bytes(q, w, h, k, tile=TILE):
    cols, _ = tiles_of(w, h, tile)
    tx, ty = k % cols, k // cols
    x0, y0 = tx * tile, ty * tile
    x1, y1 = min(w, x0 + tile), min(h, y0 + tile)
    return b"".join(q[y * w + x0:y * w + x1] for y in range(y0, y1))


def ambient(frames, w, h, windows, tile=TILE, max_share=AMBIENT_MAX_SHARE):
    """The tiles that changed between consecutive frames presented inside any (t0, t1] of `windows`. A change of more
    than `max_share` of the window is an action's (the tail of the one before), not the load's motion: left out."""
    out = set()
    cols, rows = tiles_of(w, h, tile)
    qs = [(t, coarse(g)) for t, g in frames]
    for t0, t1 in windows:
        inside = [q for t, q in qs if t0 < t <= t1]
        prior = [q for t, q in qs if t <= t0][-1:]
        seq = prior + inside
        for a, b in zip(seq, seq[1:]):
            changed = changed_both(a, b, w, h, tile)
            if len(changed) <= max_share * cols * rows:
                out |= changed
    return out


def settle(frames, mark, w, h, frame_ms, end=None, ambient_tiles=(), quiet_ms=QUIET_MS, tile=TILE):
    """The settled record of one action (module doc) from its frames [(seconds, gray)] and mark; `end` is when the
    recording of the action stopped (seconds; default one display frame after the last frame)."""
    out = {"settled_ms": None, "first_change_ms": None, "changed_after_first": 0, "settle_note": None,
           "ambient_share": 0.0, "blinks": 0, "change_frames": [], "late_change_frame": None}
    cols, rows = tiles_of(w, h, tile)
    if cols * rows:
        out["ambient_share"] = round(len(set(ambient_tiles)) / (cols * rows), 3)
    before = [f for f in frames if f[0] <= mark][-1:] or frames[:1]
    # The end flip's own frame is the harness's, not the action's: on a CI mini (2026-11-18) it carried a change in the
    # window in most rounds, "still changing 0 ms before the recording ended" at any record length (3 s and 6 s).
    after = [f for f in frames if f[0] > mark and (end is None or f[0] < end)]
    if not before or not after:
        out["settle_note"] = "no frames after the action"
        return out
    end = end if end is not None else after[-1][0] + frame_ms / 1000
    skip = set(ambient_tiles)
    prev = coarse(before[0][1])
    seen = {}  # tile -> its pictures since the mark (the one before the mark first)
    steps = []  # (frame index, changed tiles, whether every one went back to a picture it showed)
    returns = {}  # tile -> how often it went back to a picture it showed (OSCILLATION_MATCH_SHARE alike)
    pictures = {}  # tile -> its pictures since the mark, OSCILLATION_MATCH_SHARE alike folded
    for i, (t, g) in enumerate(after):
        q = coarse(g)
        changed = changed_both(prev, q, w, h, tile) - skip
        if changed:
            revisit = True
            for k in changed:
                states = seen.setdefault(k, [tile_bytes(prev[0], w, h, k, tile)])
                now = tile_bytes(q[0], w, h, k, tile)
                if not any(judge.diff_share(now, s) <= TILE_CHANGE_SHARE for s in states):
                    revisit = False
                    states.append(now)
                    del states[:-STATES_PER_TILE]
                # Oscillation matches looser: the recording's compression redraws a blinking caret a little differently.
                loose = pictures.setdefault(k, [tile_bytes(prev[0], w, h, k, tile)])
                if any(judge.diff_share(now, s) <= OSCILLATION_MATCH_SHARE for s in loose):
                    returns[k] = returns.get(k, 0) + 1
                else:
                    loose.append(now)
            steps.append((i, changed, revisit))
        prev = q
    # A tile that went back to an earlier picture OSCILLATION_RETURNS times or more, among at most OSCILLATION_STATES
    # pictures (the one before the action, then off and on), blinks: a terminal cursor and a composer caret at once,
    # more than BLINK_TILES tiles (a CI mini, 2026-11-18). A change of only such tiles is a blink, its first showing
    # included. A tile cycling through more pictures (a running animation) still counts.
    oscillating = {k for k, n in returns.items() if n >= OSCILLATION_RETURNS and len(pictures[k]) <= OSCILLATION_STATES}
    real = []
    for i, changed, revisit in steps:
        if (len(changed) <= BLINK_TILES and revisit) or (len(changed) <= OSCILLATION_TILES and changed <= oscillating):
            out["blinks"] += 1
        else:
            real.append(i)
    out["change_frames"] = real[:60]
    if not real:
        out["settle_note"] = "nothing in the window changed after the action"
        return out
    times = [f[0] for f in after]
    out["first_change_ms"] = round((times[real[0]] - mark) * 1000, 2)
    out["changed_after_first"] = len(real) - 1
    # A quiet stretch of QUIET_MS between two changes, then more change: late-change.
    for a, b in zip(real, real[1:]):
        if (times[b] - times[a]) * 1000 >= quiet_ms:
            out["late_change_frame"] = b
            break
    last = real[-1]
    if (end - times[last]) * 1000 >= quiet_ms:
        out["settled_ms"] = round((times[last] - mark) * 1000, 2)
    else:
        out["settle_note"] = (f"still changing {round((end - times[last]) * 1000)} ms before the recording ended "
                              f"({round((end - mark) * 1000)} ms after the action); quiet needs {quiet_ms:g} ms")
    out["last_change_frame"] = last
    return out


def content_states(frames, mark, w, content, tolerance):
    """The content area's pictures after the mark with repeats folded: [(first frame index, crop)], the picture
    before the mark first with index -1."""
    before = [f for f in frames if f[0] <= mark][-1:] or frames[:1]
    after = [f for f in frames if f[0] > mark]
    states = [(-1, judge.crop(before[0][1], w, content))] if before else []
    for i, (_t, g) in enumerate(after):
        c = judge.crop(g, w, content)
        if states and judge.diff_share(c, states[-1][1]) <= tolerance:
            continue
        states.append((i, c))
    return states


def flicker_frame(frames, mark, w, content, tolerance):
    """The frame index after the mark where the content went back to a picture it had already left (A, B, A), or
    None."""
    states = content_states(frames, mark, w, content, tolerance)
    for j in range(2, len(states)):
        for k in range(j - 1):
            if judge.diff_share(states[j][1], states[k][1]) <= tolerance:
                return states[j][0]
    return None


def oddities(switch, settled, flicker=None, frame_ms=16.7):
    """The oddity list [{kind, frame, ms?, detail}] of one action from its judge record (`switch`, judge_switch's
    with strip / sidebar fields), its settle record and its flicker frame."""
    out = []

    def add(kind, frame, detail):
        out.append({"kind": kind, "frame": frame, "detail": detail})

    for prefix, what in (("", "tab strip"), ("sidebar_", "sidebar")):
        if switch.get(prefix + "insert_ok") is False:
            add("placement", switch.get(prefix + "strip_first_frame"),
                f"the {what} first changed at columns/rows {switch.get(prefix + 'strip_first_cols')}, it ends changing at "
                f"{switch.get(prefix + 'strip_final_cols')}")
        if switch.get(prefix + "anim_end_ok") is False:
            add("retarget", switch.get(prefix + "anim_bad_frame"),
                f"the {what} moved away from its final layout or rested off it, then moved on "
                f"({switch.get(prefix + 'anim_bad_why') or 'distances ' + str(switch.get(prefix + 'strip_distances'))[:120]})")
    if flicker is not None:
        add("flicker", flicker, "the content went back to a picture it had already left")
    if (switch.get("blank_frames") or 0) > 0:
        add("blank", switch.get("first_blank_frame"), f"{switch['blank_frames']} blank display frames")
    if (switch.get("shift_px") or 0) > 0:
        add("shift", switch.get("first_content_frame"), f"content moved {switch['shift_px']} pt after its first paint")
    to = switch.get("to_content_ms")
    s = settled.get("settled_ms")
    if to is not None and s is not None and s > to + 2 * frame_ms:
        add("layout-after-content", settled.get("last_change_frame"),
            f"content right at {to:.1f} ms, the window still changing until {s:.1f} ms")
    if settled.get("late_change_frame") is not None:
        add("late-change", settled["late_change_frame"], f"the window held still {QUIET_MS:g} ms, then changed again")
    if s is None and settled.get("change_frames"):
        add("never-settled", settled.get("last_change_frame"), settled.get("settle_note") or "never settled")
    return out


def oddity_sheet(frames, mark, w, h, frame, reference=None):
    """A contact-sheet crop around one oddity: the frame before `frame` (after-mark index), it, the two after it and
    the end picture; PNG bytes and each tile's ms from the mark."""
    after = [f for f in frames if f[0] > mark]
    before = [f for f in frames if f[0] <= mark][-1:]
    seq = before + after  # index i after the mark is seq[i + 1]
    if frame is None or not seq:
        return None, []
    pick = [i for i in range(frame, frame + 4) if 0 <= i < len(seq)]
    tiles = [(round((seq[i][0] - mark) * 1000, 1), seq[i][1]) for i in pick]
    tiles.append(("end", reference if reference is not None else seq[-1][1]))
    return sheet(tiles, w, h, columns=len(tiles)), [ms for ms, _ in tiles]


def sheet(tiles, w, h, columns=6, gap=4):
    cols = min(columns, len(tiles))
    rows = (len(tiles) + cols - 1) // cols
    sw, sh = cols * w + (cols - 1) * gap, rows * h + (rows - 1) * gap
    out = bytearray(b"\x80" * (sw * sh))
    for index, (_ms, gray) in enumerate(tiles):
        ox, oy = (index % cols) * (w + gap), (index // cols) * (h + gap)
        for y in range(h):
            out[(oy + y) * sw + ox:(oy + y) * sw + ox + w] = gray[y * w:(y + 1) * w]
    return judge.png_gray(sw, sh, bytes(out))


def percentile(values, p):
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    index = min(len(vals) - 1, max(0, int(round(p / 100 * (len(vals) - 1)))))
    return vals[index]


def table(rows, baseline="L0", ratio=1.2):
    """Per scenario x load: first-content and settled p50/p95, frames changed after the first, the max shift,
    blank/partial frames, oddity counts by kind, and the pass rule (settled p95 within `ratio` x the baseline load's,
    no change after the first frame)."""
    out = []
    base = {}
    for row in rows:
        s = row["switches"]
        line = {"scenario": row["name"], "load": row["load"], "n": len(s),
                "excluded": len(row.get("excluded") or []),
                "first_content_p50": percentile([x.get("to_content_ms") for x in s], 50),
                "first_content_p95": percentile([x.get("to_content_ms") for x in s], 95),
                "first_frame_p50": percentile([x.get("first_change_ms") for x in s], 50),
                "settled_p50": percentile([x.get("settled_ms") for x in s], 50),
                "settled_p95": percentile([x.get("settled_ms") for x in s], 95),
                "never_settled": sum(1 for x in s if x.get("settled_ms") is None),
                "changed_after_first_max": max((x.get("changed_after_first") or 0 for x in s), default=0),
                "shift_px_max": max((x.get("shift_px") or 0 for x in s), default=0),
                "blank_frames": sum(x.get("blank_frames") or 0 for x in s),
                "partial_frames": sum(x.get("wrong_frames") or 0 for x in s),
                "oddities": {}}
        for x in s:
            for odd in x.get("oddities") or []:
                line["oddities"][odd["kind"]] = line["oddities"].get(odd["kind"], 0) + 1
        if row.get("notes"):
            line["notes"] = row["notes"][:200]
        out.append(line)
        if row["load"] == baseline:
            base[row["name"]] = line["settled_p95"]
    for line in out:
        b = base.get(line["scenario"])
        p95 = line["settled_p95"]
        line["settled_vs_baseline"] = round(p95 / b, 2) if b and p95 is not None else None
        line["pass"] = (line["n"] > 0 and line["never_settled"] == 0 and line["changed_after_first_max"] == 0
                        and (line["load"] == baseline or (b is not None and p95 is not None and p95 <= ratio * b)))
    return out


def table_markdown(lines):
    """The summary table as Markdown."""
    def ms(v):
        return "-" if v is None else f"{v:.0f}"
    head = ("| scenario | load | n | foreign-window excluded | first content p50 / p95 ms | settled p50 / p95 ms | vs L0 | never settled "
            "| changed after first (max) | oddities |\n|---|---|---|---|---|---|---|---|---|---|\n")
    body = []
    for x in lines:
        odd = ", ".join(f"{k} {v}" for k, v in sorted(x["oddities"].items())) or "0"
        if x.get("notes") and not x["n"]:
            odd = "not measured: " + x["notes"][:80].replace("|", "/")
        body.append(f"| {x['scenario']} | {x['load']} | {x['n']} | {x.get('excluded', 0)} | {ms(x['first_content_p50'])} / "
                    f"{ms(x['first_content_p95'])} | {ms(x['settled_p50'])} / {ms(x['settled_p95'])} | "
                    f"{x['settled_vs_baseline'] if x['settled_vs_baseline'] is not None else '-'} | {x['never_settled']} | "
                    f"{x['changed_after_first_max']} | {odd} |")
    return head + "\n".join(body) + "\n"
