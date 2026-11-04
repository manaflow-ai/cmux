"""Whether a bench-terminal-resize.py layout measured anything (cmux22, 2026-11-04).

A drag that moved no terminal reports zeros that read like a fast result: the light layout of jobs e37ade05 and
501a8647 dragged its divider while a restored session showed something else in front, and all 3 rounds had
resized_terminals 0 and every render counter 0. ``problems`` names what a layout lacks; bench-terminal-resize.py
records it in the layout's result and exits non-zero after writing its report.
"""

# Layouts that drag a divider through ``measure`` (each round resizes terminals and draws them).
DRAG_LAYOUTS = ("light", "stress")
# Layouts that time a split's resized terminals (``split_resize``).
SPLIT_LAYOUTS = ("split-resize", "split-resize-stress")


def problems(result):
    """What `result`, one layout's entry in the report, did not measure; [] when it measured."""
    layout = result.get("layout")
    if result.get("error"):
        return [f"{layout}: {result['error']}"]
    if layout not in DRAG_LAYOUTS + SPLIT_LAYOUTS:
        return []
    rounds = result.get("rounds") or []
    if not rounds:
        return [f"{layout}: no round ran"]
    if layout in SPLIT_LAYOUTS:
        return [f"{layout} round {index}: the split resized no terminal"
                for index, entry in enumerate(rounds, 1) if not entry.get("resized_terminals")]
    found = []
    for index, entry in enumerate(rounds, 1):
        if not entry.get("resized_terminals"):
            found.append(f"{layout} round {index}: no terminal resized in the drag")
        if not (entry.get("frames") or {}).get("frames"):
            found.append(f"{layout} round {index}: no display frame was counted")
        if not (entry.get("counters") or {}).get("frames"):
            found.append(f"{layout} round {index}: no terminal drew a frame")
    return found
