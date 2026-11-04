"""Whether a bench-terminal-resize.py layout measured anything (cmux22, 2026-11-04).

A drag that moved no terminal reports zeros that read like a fast result: the light layout of jobs e37ade05 and
501a8647 dragged its divider while a restored session showed something else in front, and all 3 rounds had
resized_terminals 0 and every render counter 0. ``problems`` names what a layout lacks; bench-terminal-resize.py
records it in the layout's result and exits non-zero after writing its report.

A build that holds terminals through a divider drag (`terminalDrag.holdSurface`, on by default since #32006) resizes
and draws no terminal in a drag that ends where it began, in either S4 arm (cmux24, 2026-11-04: OFF job b945a41d and
ON job a88aa2f9). Its layout reports `drag_holds_terminals`; its probe (one drag that ends 40 pt away, then one back)
already proved that the drag moves the divider and that a terminal's full_resize counts the new grid, so each round
needs only a counted frame and laid-out views.
"""

# Layouts that drag a divider through ``measure``.
DRAG_LAYOUTS = ("light", "stress")
# Layouts that time a split's resized terminals (``split_resize``).
SPLIT_LAYOUTS = ("split-resize", "split-resize-stress")
# Layouts that press Ctrl-Shift-L and Ctrl-Shift-H (``measure_keys``): every round resizes terminals and draws them.
KEY_LAYOUTS = ("keys", "keys-stress")


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
    held = layout in DRAG_LAYOUTS and result.get("drag_holds_terminals") is True
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
        if held:
            if frames.get("view_layouts") == 0:
                found.append(f"{name}: the drag laid out no view")
            continue
        if not entry.get("resized_terminals"):
            found.append(f"{name}: no terminal resized in the {motion}")
        if not (entry.get("counters") or {}).get("frames"):
            found.append(f"{name}: no terminal drew a frame")
    return found
