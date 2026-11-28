"""Optical pass: centers each icon's ink and lifts small open glyphs to a common size.

Usage: python3 optical.py ink.json   (measurements from measure.py)
Rewrites icons/*.json in place. Geometry is transformed (not wrapped in a <g transform>), so
stroke widths stay 1.5 and the pack builder still sees absolute coordinates. Line, Solid and
Cat share the Line measurement; each alt uses its own Line measurement.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOLERANCE = 0.25          # horizontal offsets above this are fixed (the check flags > 0.5)
V_TOLERANCE = 0.5         # vertical: tails and badges may sit a little low
MIN_EXTENT = 15.0         # smallest ink extent for non-dot glyphs, stroke included
STROKE = 1.5
DOTS = re.compile(r"(\.dot$|^list\.bullet\.item$)")
# Optical targets that differ from the bbox center: a play triangle sits right of its box center.
TARGET = {"action.resume": (12.75, 12.0), "disclosure.collapsed": (13.0, 12.0)}
# Plain rings, dots and status circles read larger than open or square glyphs at the same extent
# (Leo, 2026-10-02): an ink target about 12% under the old r=8.5 circle. Composite circles (a ring
# with content: account, clear, globe, clock) keep full size.
CIRCLE_EXTENT = 16.25
CIRCLE_MIN_EXTENT = 13.0
CIRCLES = {
    "task.status.backlog", "task.status.canceled", "task.status.done", "task.status.started",
    "task.status.todo", "task.status.triage", "state.idle", "state.off", "status.attention",
    "status.complete", "status.disconnected", "status.error", "status.info", "status.inprogress",
    "status.needsinput", "status.success", "status.running", "status.progress",
}

NUM = re.compile(r"-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")


def fmt(v):
    v = round(v, 3)
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


ARITY = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0}


def transform_path(d, s, ox, oy):
    out, i, cmd = [], 0, None
    text = d
    # Tokenize with arc-flag awareness.
    pos, tokens = 0, []
    current = None
    argn = 0
    while pos < len(text):
        c = text[pos]
        if c.isalpha():
            current, argn = c, 0
            tokens.append(c)
            pos += 1
            continue
        if c in " ,\t\n":
            pos += 1
            continue
        if current and current.upper() == "A" and argn % 7 in (3, 4) and c in "01":
            tokens.append(float(c))
            pos += 1
            argn += 1
            continue
        m = NUM.match(text, pos)
        if not m:
            raise ValueError(f"bad path {d!r} at {pos}")
        tokens.append(float(m.group()))
        pos = m.end()
        argn += 1
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if isinstance(t, str):
            cmd = t
            out.append(cmd)
            i += 1
            if cmd.upper() == "Z":
                continue
        n = ARITY[cmd.upper()]
        args = tokens[i:i + n]
        i += n
        rel = cmd.islower()
        up = cmd.upper()
        if up == "H":
            v = args[0] * s if rel else args[0] * s + ox
            res = [v]
        elif up == "V":
            v = args[0] * s if rel else args[0] * s + oy
            res = [v]
        elif up == "A":
            rx, ry, rot, la, sw, x, y = args
            if rel:
                x, y = x * s, y * s
            else:
                x, y = x * s + ox, y * s + oy
            res = [rx * s, ry * s, rot, int(la), int(sw), x, y]
        else:
            res = []
            for k in range(0, n, 2):
                x, y = args[k], args[k + 1]
                res += [x * s, y * s] if rel else [x * s + ox, y * s + oy]
        out.append(" ".join(str(v) if isinstance(v, int) else fmt(v) for v in res))
        # Subsequent implicit repeats keep the same command letter; emit separators.
        if i < len(tokens) and not isinstance(tokens[i], str):
            out.append(" ")
    return "".join(x if x.isalpha() and len(x) == 1 else x for x in out)


def attr(tag, name):
    m = re.search(rf"\s{name}='([^']*)'", tag)
    return m.group(1) if m else None


def set_attr(tag, name, value):
    if attr(tag, name) is None:
        return re.sub(r"\s*(/?)>$", lambda m: f" {name}='{value}'{m.group(1) and '/'}>", tag)
    return re.sub(rf"(\s{name}=')[^']*(')", lambda m: m.group(1) + value + m.group(2), tag)


def transform_svg(svg, s, ox, oy):
    def element(m):
        tag, name = m.group(0), m.group(1)
        if name in ("svg", "mask", "defs", "g"):
            return tag
        existing = attr(tag, "transform")
        if existing:
            return set_attr(tag, "transform", f"matrix({fmt(s)} 0 0 {fmt(s)} {fmt(ox)} {fmt(oy)}) {existing}")
        X = lambda v: fmt(float(v) * s + ox)
        Y = lambda v: fmt(float(v) * s + oy)
        S = lambda v: fmt(float(v) * s)
        if name == "path":
            tag = set_attr(tag, "d", transform_path(attr(tag, "d"), s, ox, oy))
        elif name == "circle":
            tag = set_attr(set_attr(set_attr(tag, "cx", X(attr(tag, "cx"))), "cy", Y(attr(tag, "cy"))), "r", S(attr(tag, "r")))
        elif name == "ellipse":
            for k, f in (("cx", X), ("cy", Y), ("rx", S), ("ry", S)):
                tag = set_attr(tag, k, f(attr(tag, k)))
        elif name == "rect":
            # The mask's full-canvas background stays put.
            if attr(tag, "x") in (None, "0") and attr(tag, "y") in (None, "0") and attr(tag, "width") == "24" and attr(tag, "height") == "24":
                return tag
            tag = set_attr(tag, "x", X(attr(tag, "x") or 0))
            tag = set_attr(tag, "y", Y(attr(tag, "y") or 0))
            for k in ("width", "height", "rx", "ry"):
                if attr(tag, k) is not None:
                    tag = set_attr(tag, k, S(attr(tag, k)))
        else:
            return tag
        dash = attr(tag, "stroke-dasharray")
        if dash and attr(tag, "pathLength") is None and s != 1:
            tag = set_attr(tag, "stroke-dasharray", " ".join(S(v) for v in re.split(r"[\s,]+", dash.strip())))
        return tag
    return re.sub(r"<(\w+)\b[^>]*>", element, svg)


def plan(name, box):
    extent = max(box["w"], box["h"])
    s = 1.0
    if name in CIRCLES:
        if extent > CIRCLE_EXTENT + 0.01 or extent < CIRCLE_MIN_EXTENT - 0.01:
            s = (max(CIRCLE_MIN_EXTENT, min(extent, CIRCLE_EXTENT)) - STROKE) / (extent - STROKE)
    elif not DOTS.search(name) and extent < MIN_EXTENT - 0.01:
        s = (MIN_EXTENT - STROKE) / (extent - STROKE)
    tx, ty = TARGET.get(name, (12.0, 12.0))
    cx, cy = box["cx"], box["cy"]
    if s == 1.0 and abs(cx - tx) <= TOLERANCE and abs(cy - ty) <= V_TOLERANCE:
        return None
    if s == 1.0 and abs(cx - tx) <= TOLERANCE:
        cx = tx
    if s == 1.0 and abs(cy - ty) <= V_TOLERANCE:
        cy = ty
    # p' = s * (p - c) + target, with the shift snapped to a quarter unit.
    ox = round((tx - s * cx) * 4) / 4 if s == 1.0 else tx - s * cx
    oy = round((ty - s * cy) * 4) / 4 if s == 1.0 else ty - s * cy
    return s, ox, oy


def main():
    ink = json.loads(Path(sys.argv[1]).read_text())
    changes = []
    for path in sorted((ROOT / "icons").glob("*.json")):
        data = json.loads(path.read_text())
        for icon in data["icons"]:
            name = icon["name"]
            p = plan(name, ink[f"{name}|line"])
            if p:
                for k in ("line", "solid", "cat"):
                    if icon.get(k):
                        icon[k] = transform_svg(icon[k], *p)
                changes.append((name, p))
            for i, alt in enumerate(icon.get("alts") or []):
                box = ink.get(f"{name}|alt{i}.line")
                p = box and plan(name, box)
                if p:
                    for k in ("line", "solid"):
                        if alt.get(k):
                            alt[k] = transform_svg(alt[k], *p)
                    changes.append((f"{name} alt{i}", p))
        path.write_text(json.dumps(data, indent=1, ensure_ascii=False))
    for name, (s, ox, oy) in changes:
        print(f"{name:40s} scale {s:.3f} shift {ox:+.2f} {oy:+.2f}")
    print(f"{len(changes)} transformed")


if __name__ == "__main__":
    main()
