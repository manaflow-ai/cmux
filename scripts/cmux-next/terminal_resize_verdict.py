"""Whether a bench-terminal-resize.py layout measured anything (cmux22, 2026-11-04).

A drag that moved no terminal reports zeros that read like a fast result: the light layout of jobs e37ade05 and
501a8647 dragged its divider while a restored session showed something else in front, and all 3 rounds had
resized_terminals 0 and every render counter 0. ``problems`` names what a layout lacks; bench-terminal-resize.py
records it in the layout's result and exits non-zero after writing its report.

A build that holds terminals through a divider drag (`terminalDrag.holdSurface`, on by default since #32006) resizes
and draws no terminal in a drag that ends where it began, in either S4 arm (cmux24, 2026-11-04: OFF job b945a41d and
ON job a88aa2f9). Each drag round reports `holds_terminals` (the layout `drag_holds_terminals`, for reports without it);
its probe (one drag that ends 40 pt away, then one back) already proved that the drag moves the divider and that the
render counters count the new grid, so a held round needs only a counted frame and laid-out views.
"""

# A terminal's full rebuilds for a new grid (GhosttyNextKit render counters): `full_resize` when the drawn grid changes
# size, `full_swap` when the reflow preview starts or ends. A held grid (a key resize, a drag's release) draws its new
# size through the preview, so it counts as a swap: job b5834b1d on cmux24 had full_resize 0 and full_swap equal to the
# grids sent in every keys round.
RESIZE_COUNTERS = ("full_resize", "full_swap")

# Layouts that drag a divider through ``measure``.
DRAG_LAYOUTS = ("light", "stress")
# Layouts that time a split's resized terminals (``split_resize``).
SPLIT_LAYOUTS = ("split-resize", "split-resize-stress")
# Layouts that press Ctrl-Shift-L and Ctrl-Shift-H (``measure_keys``): every round resizes terminals and draws them.
KEY_LAYOUTS = ("keys", "keys-stress", "keys-held", "keys-stress-held")


def rebuilds(counters):
    """A terminal's full rebuilds for a new grid so far (``RESIZE_COUNTERS``)."""
    return sum(int(counters.get(key, 0)) for key in RESIZE_COUNTERS)


def resized(before, after):
    """The terminals of `after` (bench-terminal-resize.py `surfaces()` rows, paired with `before` by id) whose full
    rebuilds for a new grid grew: each one resized at least once in between."""
    by_id = {row["id"]: row for row in before}
    return sum(1 for row in after
               if row["id"] in by_id and rebuilds(row["counters"]) > rebuilds(by_id[row["id"]]["counters"]))


def problems(result):
    """What `result`, one layout's entry in the report, did not measure; [] when it measured."""
    layout = result.get("layout")
    if result.get("error"):
        return [f"{layout}: {result['error']}"]
    if layout not in DRAG_LAYOUTS + SPLIT_LAYOUTS + KEY_LAYOUTS:
        return []
    rounds = result.get("rounds") or []
    if not rounds:
        return [f"{layout}: no round ran"]
    if layout in SPLIT_LAYOUTS:
        # Each entry is one split action (a round runs several).
        return [f"{layout} action {index} ({entry.get('action', '?')}): the split resized no terminal"
                for index, entry in enumerate(rounds, 1) if not entry.get("resized_terminals")]
    motion = "key resize" if layout in KEY_LAYOUTS else "drag"
    found = []
    for index, entry in enumerate(rounds, 1):
        name = f"{layout} round {index}"
        if "arm" in entry:
            name += f" ({'build' if entry['arm'] is None else ('on' if entry['arm'] else 'off')})"
        if entry.get("error"):
            found.append(f"{name}: {entry['error']}")
            continue
        frames = entry.get("frames") or {}
        if not frames.get("frames"):
            found.append(f"{name}: no display frame was counted")
        # The hold as the round ran (an --ab of the hold itself changes it per round), else the layout's.
        holds = entry["holds_terminals"] if "holds_terminals" in entry else result.get("drag_holds_terminals")
        if layout in DRAG_LAYOUTS and holds is True:
            if not frames.get("view_layouts"):
                found.append(f"{name}: the drag laid out no view")
            continue
        if not entry.get("resized_terminals"):
            found.append(f"{name}: no terminal resized in the {motion}")
        if not (entry.get("counters") or {}).get("frames"):
            found.append(f"{name}: no terminal drew a frame")
    return found
