"""Whether a bench-terminal-resize.py layout measured anything, and whether its terminals followed their panes.

A drag that moved no terminal reports zeros that read like a fast result: the light layout of jobs e37ade05 and
501a8647 dragged its divider while a restored session showed something else in front, and all 3 rounds had
resized_terminals 0 and every render counter 0. ``problems`` names what a layout lacks; bench-terminal-resize.py
records it in the layout's result and exits non-zero after writing its report.

A drag or a key resize also fails when a terminal does not change size with its pane (Lead, cmux-ad m16 (b),
2026-11-05): in every frame of the motion, the size the host asks of each shown terminal must be its pane's size.
`debug.terminal_display` samples each terminal once per display frame (``follow``): `held` frames are frames in which
the host asked another size (a surface held through a drag by `terminalDrag.holdSurface`, or through a key resize's
spring), `lagging` frames are frames in which the layer still showed another size. Held frames fail the round;
lagging frames are data only (the frame owner keeps a frame for 1-4 refreshes by design; films judge that). A held
drag used to pass on laid-out views alone (`holds_terminals`, still reported as data): it fails now.
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


def follow(display):
    """Takes `debug.terminal_display`'s pane check out of its stop reply `display` (``DebugTerminalPaneFollow``): the
    frames sampled and, per terminal (by tab key), frames, held and lagging frames and the first 3 of each, with the
    round's totals. None when the build has no pane check."""
    terminals = display.pop("terminals_followed", None)
    frames = display.pop("follow_frames", None)
    if terminals is None:
        return None
    return {"frames": int(frames or 0), "terminals": terminals,
            "held_frames": sum(int(t.get("held") or 0) for t in terminals.values()),
            "held_terminals": sum(1 for t in terminals.values() if t.get("held")),
            "lagging_frames": sum(int(t.get("lagging") or 0) for t in terminals.values())}


def _size(pair):
    return "x".join(f"{v:g}" for v in pair) if isinstance(pair, (list, tuple)) else "?"


def held_problem(entry, motion):
    """Why the round's terminals did not follow their panes, or None: a terminal held another size than its pane's in
    some frame, or the round has no pane check to judge."""
    checked = entry.get("follow")
    if not checked or not checked.get("terminals"):
        return f"no terminal was checked against its pane in the {motion} (no terminals_followed from debug.terminal_display)"
    if not checked.get("frames"):
        return f"the pane check sampled no frame in the {motion}"
    held = sorted(((key, t) for key, t in checked["terminals"].items() if t.get("held")),
                  key=lambda item: (-int(item[1]["held"]), item[0]))
    if not held:
        return None
    named = []
    for key, terminal in held[:3]:
        first = ", ".join(f"frame {m.get('frame')}: pane {_size(m.get('area'))}, asked {_size(m.get('asked'))}, "
                          f"shown {_size(m.get('shown'))}" for m in terminal.get("first_held") or [])
        named.append(f"{key} held {terminal['held']} of {terminal.get('frames')} frames ({first})")
    more = f"; and {len(held) - 3} more" if len(held) > 3 else ""
    return (f"{len(held)} of {len(checked['terminals'])} terminals did not change size with their pane in the {motion}: "
            + "; ".join(named) + more)


def problems(result):
    """What `result`, one layout's entry in the report, did not measure, and each drag or key round in which a terminal
    did not change size with its pane; [] when it measured and every terminal followed."""
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
        held = held_problem(entry, motion)
        if held:
            found.append(f"{name}: {held}")
        frames = entry.get("frames") or {}
        if not frames.get("frames"):
            found.append(f"{name}: no display frame was counted")
        if not entry.get("resized_terminals"):
            found.append(f"{name}: no terminal resized in the {motion}")
        if not (entry.get("counters") or {}).get("frames"):
            found.append(f"{name}: no terminal drew a frame")
    return found
