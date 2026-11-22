#!/usr/bin/env python3
"""Per-mover progress timelines for one-motion-trace.py (an SVG per motion, no dependencies).

Each mover (the sidebar's width, a pane's frame, a pane's laid-out content, a terminal surface, a page) is drawn as
its progress from where it started (0) to where it landed (1) against ms since the action, on the component that
travels furthest. Movers on one timeline draw one curve; a mover that waits for another starts to the right of it,
and content that lays out after its pane landed jumps at the far right.

    one_motion_plot.py OUT_DIR      redraw every motion of OUT_DIR/one-motion.json from its trace-<motion>.json
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from one_motion_series import progress, series  # noqa: E402

# The categorical order (light mode), fixed: a mover keeps its slot by its rank in the motion's sorted mover list.
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
INK, MUTED, GRID, SURFACE = "#1f1f1e", "#6b6a64", "#e4e3dd", "#ffffff"
WIDTH, HEIGHT, LEFT, RIGHT, TOP, BOTTOM = 860, 360, 56, 210, 40, 44


def svg(name, curves, acted_at, end_ms):
    plot_w, plot_h = WIDTH - LEFT - RIGHT, HEIGHT - TOP - BOTTOM
    start_ms = -50.0
    x = lambda ms: LEFT + (ms - start_ms) / (end_ms - start_ms) * plot_w  # noqa: E731
    y = lambda p: TOP + (1 - max(-0.15, min(1.15, p))) * plot_h  # noqa: E731
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}" '
           f'font-family="-apple-system, Helvetica, Arial, sans-serif" font-size="12">',
           f'<rect width="{WIDTH}" height="{HEIGHT}" fill="{SURFACE}"/>',
           f'<text x="{LEFT}" y="22" fill="{INK}" font-size="14" font-weight="600">{name}: progress of each mover '
           f'(0 where it started, 1 where it landed)</text>']
    for p in (0, 0.5, 1):
        out.append(f'<line x1="{LEFT}" x2="{LEFT + plot_w}" y1="{y(p):.1f}" y2="{y(p):.1f}" stroke="{GRID}"/>')
        out.append(f'<text x="{LEFT - 8}" y="{y(p) + 4:.1f}" fill="{MUTED}" text-anchor="end">{p:g}</text>')
    step = 100 if end_ms - start_ms > 500 else 50
    tick = 0
    while tick <= end_ms:
        out.append(f'<line x1="{x(tick):.1f}" x2="{x(tick):.1f}" y1="{TOP + plot_h}" y2="{TOP + plot_h + 4}" stroke="{MUTED}"/>')
        out.append(f'<text x="{x(tick):.1f}" y="{TOP + plot_h + 18}" fill="{MUTED}" text-anchor="middle">{tick}</text>')
        tick += step
    out.append(f'<text x="{LEFT + plot_w / 2}" y="{HEIGHT - 8}" fill="{MUTED}" text-anchor="middle">ms after the key</text>')
    out.append(f'<line x1="{x(0):.1f}" x2="{x(0):.1f}" y1="{TOP}" y2="{TOP + plot_h}" stroke="{MUTED}" stroke-dasharray="3 3"/>')
    for index, (label, points) in enumerate(curves):
        color = SERIES[index % len(SERIES)] if index < len(SERIES) else MUTED
        path = " ".join(f"{'M' if i == 0 else 'L'}{x(t - acted_at):.1f},{y(p):.1f}"
                        for i, (t, p) in enumerate(points) if start_ms <= t - acted_at <= end_ms)
        if not path:
            continue
        out.append(f'<path d="{path}" fill="none" stroke="{color}" stroke-width="2" stroke-linejoin="round">'
                   f'<title>{label}</title></path>')
        ly = TOP + 8 + index * 18
        out.append(f'<line x1="{WIDTH - RIGHT + 16}" x2="{WIDTH - RIGHT + 32}" y1="{ly}" y2="{ly}" stroke="{color}" stroke-width="2"/>')
        out.append(f'<text x="{WIDTH - RIGHT + 38}" y="{ly + 4}" fill="{INK}">{label}</text>')
    out.append("</svg>")
    return "\n".join(out)


def write_all(report, out_dir):
    """An SVG per motion of `report` (one-motion.json), from the trace-<motion>.json beside it."""
    for run in report.get("runs") or []:
        name = run["motion"]
        path = os.path.join(out_dir, f"trace-{name}.json")
        if not os.path.exists(path):
            continue
        samples = json.load(open(path)).get("samples") or []
        movers = run.get("movers") or {}
        curves = [(label, shaped) for label, points in sorted(series(samples).items())
                  if label in movers and (shaped := progress(points))]
        end_ms = max([m["end_ms"] for m in movers.values()] or [500])
        open(os.path.join(out_dir, f"{name}.svg"), "w").write(svg(name, curves, float(run.get("acted_at_ms") or 0),
                                                              max(300.0, end_ms + 60)))


if __name__ == "__main__":
    folder = sys.argv[1]
    write_all(json.load(open(os.path.join(folder, "one-motion.json"))), folder)
