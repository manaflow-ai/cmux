"""The ON/OFF arms of one bench-terminal-resize.py launch (FRAME OWNER S4, 2026-11-04).

With `--ab KEY` each round runs once with the boolean tunable KEY off and once with it on, in one launch of one build
(`debug.tunables set`), and the order alternates per round (off then on, then on then off), so a difference between
launches (a whole-window +1 refresh that comes and goes between launches, STATUS 11574) cannot read as a difference
between the arms. ``summaries`` pools each arm's rounds: frame intervals and main-thread ms per frame as
distributions (p50, p95, p99, max), missed refreshes (and per cause, `missed_split`), the grids each terminal got per
key press, and the frames in which a terminal was held at another size than its pane's or showed another size (the
pane check, `held_frames` and `lagging_frames`).
"""


def order(index, ab):
    """The arms of round `index` (0-based): [None] (the build as it is) without `ab`, else off/on or on/off."""
    if not ab:
        return [None]
    return [False, True] if index % 2 == 0 else [True, False]


def label(arm):
    return "build" if arm is None else ("on" if arm else "off")


def distribution(values):
    """p50, p95, p99 and max of `values` (nearest rank, as `debug.frames` computes its percentiles); None when empty."""
    values = sorted(v for v in values or [] if v is not None)
    if not values:
        return None
    pick = lambda q: values[min(len(values) - 1, int(q * (len(values) - 1) + 0.5))]
    return {"n": len(values), "p50": round(pick(0.5), 2), "p95": round(pick(0.95), 2), "p99": round(pick(0.99), 2),
            "max": round(values[-1], 2)}


def motion(main_ms, view_layouts):
    """The main-thread ms of the frames that laid out a view (the spring's frames), when the reply had both arrays."""
    if not main_ms or not view_layouts or len(main_ms) != len(view_layouts):
        return []
    return [ms for ms, layouts in zip(main_ms, view_layouts) if layouts]


def summaries(rounds):
    """Per arm label: rounds, frames, missed refreshes and the pooled distributions of the rounds' raw arrays
    (`raw`: intervals_ms, main_ms, motion_main_ms), and for key presses the most grids one terminal got in one press
    and the presses in which a terminal got more than one (the lead's rule: at most one grid per press), and the rounds'
    held and lagging frames summed over their terminals (`held_rounds`: rounds with a held frame)."""
    out = {}
    for entry in rounds:
        if entry.get("error"):
            continue
        arm = out.setdefault(label(entry.get("arm")), {"rounds": 0, "frames": 0, "missed": 0, "intervals": [], "main": [],
                                                         "motion": [], "max_grids_per_press": 0, "presses_over_one_grid": 0,
                                                         "held_frames": 0, "held_rounds": 0, "lagging_frames": 0,
                                                         "missed_split": {}})
        frames = entry.get("frames") or {}
        raw = entry.get("raw") or {}
        arm["rounds"] += 1
        arm["frames"] += int(frames.get("frames") or 0)
        arm["missed"] += int(frames.get("missed") or 0)
        for cause, count in (frames.get("missed_split") or {}).items():
            arm["missed_split"][cause] = arm["missed_split"].get(cause, 0) + int(count or 0)
        arm["intervals"] += raw.get("intervals_ms") or []
        arm["main"] += raw.get("main_ms") or []
        arm["motion"] += raw.get("motion_main_ms") or []
        arm["held_frames"] += int(entry.get("held_frames") or 0)
        arm["held_rounds"] += bool(entry.get("held_frames"))
        arm["lagging_frames"] += int(entry.get("lagging_frames") or 0)
        for press in entry.get("presses") or []:
            grids = int(press.get("max_grids_per_terminal") or 0)
            arm["max_grids_per_press"] = max(arm["max_grids_per_press"], grids)
            arm["presses_over_one_grid"] += grids > 1
    for arm in out.values():
        arm["interval_ms"] = distribution(arm.pop("intervals"))
        arm["main_ms"] = distribution(arm.pop("main"))
        arm["motion_main_ms"] = distribution(arm.pop("motion"))
    return out
