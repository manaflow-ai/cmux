#!/usr/bin/env python3
"""Builds the cmux icon pack from the authored SVGs in design/icons/source/.

Each authored icon has a Line, a Solid and optionally a Cat drawing, written as plain SVG on a 24-unit
grid (design/icons/SPEC.md). Native (CmuxNextIcons) and web (the agent pane) draw the same flattened
form, so neither needs an SVG engine:

    {"id": "cmux", "version": 1, "grid": 24,
     "icons": {"agent.chat": {"line": [layer...], "solid": [layer...], "cat": [layer...]}}}

A layer is {"d": path, "op": op} plus optional fields:
- d uses only absolute M, L, C and Z. Arcs, quadratics, rects, circles and ellipses become cubics, and
  every transform is applied.
- op is "stroke", "fill", "clearFill" or "clearStroke". Clear ops erase what earlier layers drew (an SVG
  mask's black shapes); masks are always the first drawn content, so a flat list is exact.
- w: stroke width (stroke ops). Caps and joins are round unless "cap" or "join" says otherwise.
- alpha: 0-1 opacity. dash and dashPhase: dash pattern in grid units (pathLength already resolved).
- accent: true for Cat-accent layers, drawn in the accent color.

Also writes the catalog (name, meaning, SF Symbol fallback, dense style, family) and the generated Swift
IconName members. Run with --check to verify the outputs are up to date.
"""
import argparse
import json
import math
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / "design" / "icons" / "source"
NATIVE = REPO / "Packages" / "macOS" / "CmuxNext" / "Sources" / "CmuxNextIcons"
WEB = REPO / "webviews" / "src" / "agent-session" / "acpmux" / "icons"
OUTPUTS = {
    "pack_native": NATIVE / "Resources" / "cmux-icons.json",
    "catalog_native": NATIVE / "Resources" / "icon-catalog.json",
    "names_swift": NATIVE / "IconName+Members.swift",
    "catalog_swift": NATIVE / "IconName+Catalog.swift",
    "pack_web": WEB / "cmuxIcons.json",
}
NUM = re.compile(r"-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")
ARITY = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0}
DENSE_SOLID = re.compile(r"^(status|state|task\.status)\.|\.dot$")


def fmt(v):
    s = f"{round(v, 3):.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


# MARK: Affine transforms, as (a, b, c, d, e, f) like SVG matrix().

IDENTITY = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


def multiply(m, n):
    a, b, c, d, e, f = m
    a2, b2, c2, d2, e2, f2 = n
    return (a * a2 + c * b2, b * a2 + d * b2, a * c2 + c * d2, b * c2 + d * d2, a * e2 + c * f2 + e, b * e2 + d * f2 + f)


def parse_transform(text):
    m = IDENTITY
    for name, args in re.findall(r"(\w+)\s*\(([^)]*)\)", text or ""):
        v = [float(x) for x in NUM.findall(args)]
        if name == "matrix":
            t = tuple(v)
        elif name == "translate":
            t = (1, 0, 0, 1, v[0], v[1] if len(v) > 1 else 0)
        elif name == "scale":
            t = (v[0], 0, 0, v[1] if len(v) > 1 else v[0], 0, 0)
        elif name == "rotate":
            r = math.radians(v[0])
            t = (math.cos(r), math.sin(r), -math.sin(r), math.cos(r), 0, 0)
            if len(v) == 3:
                t = multiply(multiply((1, 0, 0, 1, v[1], v[2]), t), (1, 0, 0, 1, -v[1], -v[2]))
        else:
            raise ValueError(f"unsupported transform {name}")
        m = multiply(m, t)
    return m


def apply(m, x, y):
    a, b, c, d, e, f = m
    return a * x + c * y + e, b * x + d * y + f


def scale_of(m):
    return math.sqrt(abs(m[0] * m[3] - m[1] * m[2]))


# MARK: Paths as segment lists: ("M", p) ("L", p) ("C", p1, p2, p) ("Z",)


def tokens(d):
    """Tokenizes path data; arc flags may be packed ('a1 1 0 011.5 2')."""
    out, pos, cmd, argn = [], 0, None, 0
    while pos < len(d):
        ch = d[pos]
        if ch.isalpha():
            cmd, argn = ch, 0
            out.append(ch)
            pos += 1
        elif ch in " ,\t\n\r":
            pos += 1
        elif cmd and cmd.upper() == "A" and argn % 7 in (3, 4) and ch in "01":
            out.append(float(ch))
            pos += 1
            argn += 1
        else:
            m = NUM.match(d, pos)
            if not m:
                raise ValueError(f"bad path data at {pos}: {d!r}")
            out.append(float(m.group()))
            pos = m.end()
            argn += 1
    return out


def arc_to_cubics(x1, y1, rx, ry, phi, large, sweep, x2, y2):
    """SVG arc to cubic Beziers (SVG implementation notes, F.6.5)."""
    if rx == 0 or ry == 0 or (x1 == x2 and y1 == y2):
        return [("L", (x2, y2))]
    rx, ry = abs(rx), abs(ry)
    phi = math.radians(phi)
    cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = cp * dx + sp * dy, -sp * dx + cp * dy
    lam = (x1p / rx) ** 2 + (y1p / ry) ** 2
    if lam > 1:
        rx, ry = rx * math.sqrt(lam), ry * math.sqrt(lam)
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    coef = math.sqrt(max(0.0, num / den)) * (-1 if large == sweep else 1)
    cxp, cyp = coef * rx * y1p / ry, -coef * ry * x1p / rx
    cx, cy = cp * cxp - sp * cyp + (x1 + x2) / 2, sp * cxp + cp * cyp + (y1 + y2) / 2

    def angle(ux, uy, vx, vy):
        a = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        return a

    t1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dt = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dt > 0:
        dt -= 2 * math.pi
    elif sweep and dt < 0:
        dt += 2 * math.pi
    n = max(1, math.ceil(abs(dt) / (math.pi / 2) - 1e-9))
    step = dt / n
    k = 4 / 3 * math.tan(step / 4)
    segs = []

    def point(t):
        x, y = rx * math.cos(t), ry * math.sin(t)
        return cp * x - sp * y + cx, sp * x + cp * y + cy

    def deriv(t):
        x, y = -rx * math.sin(t), ry * math.cos(t)
        return cp * x - sp * y, sp * x + cp * y

    t = t1
    for _ in range(n):
        p0, p3 = point(t), point(t + step)
        d0, d3 = deriv(t), deriv(t + step)
        segs.append(("C", (p0[0] + k * d0[0], p0[1] + k * d0[1]), (p3[0] - k * d3[0], p3[1] - k * d3[1]), p3))
        t += step
    segs[-1] = ("C", segs[-1][1], segs[-1][2], (x2, y2))
    return segs


def parse_path(d):
    toks, i, cmd = tokens(d), 0, None
    segs, cur, start, last_c, last_q = [], (0.0, 0.0), (0.0, 0.0), None, None
    while i < len(toks):
        if isinstance(toks[i], str):
            cmd = toks[i]
            i += 1
            if cmd.upper() == "Z":
                segs.append(("Z",))
                cur, last_c, last_q = start, None, None
                continue
        if cmd is None or cmd.upper() == "Z":
            raise ValueError(f"path data has a number without a command: {d!r}")
        n = ARITY[cmd.upper()]
        a = toks[i:i + n]
        i += n
        rel, up = cmd.islower(), cmd.upper()
        ox, oy = cur if rel else (0.0, 0.0)
        if up == "M":
            cur = start = (a[0] + ox, a[1] + oy)
            segs.append(("M", cur))
            cmd = "l" if rel else "L"   # implicit lineto after moveto
            last_c = last_q = None
            continue
        if up == "L":
            p = (a[0] + ox, a[1] + oy)
            segs.append(("L", p))
            last_c = last_q = None
        elif up == "H":
            p = (a[0] + ox if rel else a[0], cur[1])
            segs.append(("L", p))
            last_c = last_q = None
        elif up == "V":
            p = (cur[0], a[0] + oy if rel else a[0])
            segs.append(("L", p))
            last_c = last_q = None
        elif up == "C":
            c1, c2, p = (a[0] + ox, a[1] + oy), (a[2] + ox, a[3] + oy), (a[4] + ox, a[5] + oy)
            segs.append(("C", c1, c2, p))
            last_c, last_q = c2, None
        elif up == "S":
            c1 = (2 * cur[0] - last_c[0], 2 * cur[1] - last_c[1]) if last_c else cur
            c2, p = (a[0] + ox, a[1] + oy), (a[2] + ox, a[3] + oy)
            segs.append(("C", c1, c2, p))
            last_c, last_q = c2, None
        elif up in ("Q", "T"):
            if up == "Q":
                q, p = (a[0] + ox, a[1] + oy), (a[2] + ox, a[3] + oy)
            else:
                q = (2 * cur[0] - last_q[0], 2 * cur[1] - last_q[1]) if last_q else cur
                p = (a[0] + ox, a[1] + oy)
            c1 = (cur[0] + 2 / 3 * (q[0] - cur[0]), cur[1] + 2 / 3 * (q[1] - cur[1]))
            c2 = (p[0] + 2 / 3 * (q[0] - p[0]), p[1] + 2 / 3 * (q[1] - p[1]))
            segs.append(("C", c1, c2, p))
            last_c, last_q = None, q
        elif up == "A":
            p = (a[5] + ox, a[6] + oy)
            segs += arc_to_cubics(cur[0], cur[1], a[0], a[1], a[2], int(a[3]), int(a[4]), p[0], p[1])
            last_c = last_q = None
        cur = p
    return segs


def ellipse(cx, cy, rx, ry):
    return ([("M", (cx + rx, cy))] + arc_to_cubics(cx + rx, cy, rx, ry, 0, 0, 1, cx - rx, cy)
            + arc_to_cubics(cx - rx, cy, rx, ry, 0, 0, 1, cx + rx, cy) + [("Z",)])


def rect(x, y, w, h, rx, ry):
    rx, ry = min(rx, w / 2), min(ry, h / 2)
    if rx <= 0 or ry <= 0:
        return [("M", (x, y)), ("L", (x + w, y)), ("L", (x + w, y + h)), ("L", (x, y + h)), ("Z",)]
    segs = [("M", (x + rx, y)), ("L", (x + w - rx, y))]
    segs += arc_to_cubics(x + w - rx, y, rx, ry, 0, 0, 1, x + w, y + ry)
    segs.append(("L", (x + w, y + h - ry)))
    segs += arc_to_cubics(x + w, y + h - ry, rx, ry, 0, 0, 1, x + w - rx, y + h)
    segs.append(("L", (x + rx, y + h)))
    segs += arc_to_cubics(x + rx, y + h, rx, ry, 0, 0, 1, x, y + h - ry)
    segs.append(("L", (x, y + ry)))
    segs += arc_to_cubics(x, y + ry, rx, ry, 0, 0, 1, x + rx, y)
    segs.append(("Z",))
    return segs


def transformed(segs, m):
    out = []
    for s in segs:
        if s[0] == "Z":
            out.append(s)
        else:
            out.append((s[0],) + tuple(apply(m, *p) for p in s[1:]))
    return out


def length(segs):
    total, cur, start = 0.0, (0.0, 0.0), (0.0, 0.0)
    for s in segs:
        if s[0] == "M":
            cur = start = s[1]
        elif s[0] == "L":
            total += math.dist(cur, s[1])
            cur = s[1]
        elif s[0] == "C":
            prev = cur
            for k in range(1, 33):
                t = k / 32
                mt = 1 - t
                p = tuple(mt ** 3 * cur[j] + 3 * mt * mt * t * s[1][j] + 3 * mt * t * t * s[2][j] + t ** 3 * s[3][j] for j in (0, 1))
                total += math.dist(prev, p)
                prev = p
            cur = s[3]
        elif s[0] == "Z":
            total += math.dist(cur, start)
            cur = start
    return total


def serialize(segs):
    parts = []
    for s in segs:
        if s[0] == "Z":
            parts.append("Z")
        else:
            parts.append(s[0] + " ".join(f"{fmt(x)} {fmt(y)}" for x, y in s[1:]))
    return "".join(parts)


# MARK: SVG tree to layers

INHERITED = ("fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "class")


def color_kind(value):
    v = (value or "").strip().lower()
    if v in ("", "none", "transparent"):
        return None
    if v in ("#000", "#000000", "black"):
        return "black"
    if v in ("#fff", "#ffffff", "white"):
        return "white"
    if "accent" in v:
        return "accent"
    return "ink"


def geometry(el, tag):
    a = el.attrib
    g = lambda k, d=0.0: float(a.get(k, d))
    if tag == "path":
        return parse_path(a["d"])
    if tag == "circle":
        return ellipse(g("cx"), g("cy"), g("r"), g("r"))
    if tag == "ellipse":
        return ellipse(g("cx"), g("cy"), g("rx"), g("ry"))
    if tag == "rect":
        rx = a.get("rx", a.get("ry", "0"))
        ry = a.get("ry", rx)
        return rect(g("x"), g("y"), g("width"), g("height"), float(rx), float(ry))
    if tag == "line":
        return [("M", (g("x1"), g("y1"))), ("L", (g("x2"), g("y2")))]
    raise ValueError(f"unsupported element <{tag}>")


def inherit(style, el):
    style = dict(style)
    for k in INHERITED:
        if k in el.attrib:
            style[k] = el.attrib[k]
    return style


def walk(el, style, m, masks, out, root_style, in_mask=False):
    tag = el.tag.split("}")[-1]
    if tag in ("defs", "mask", "title", "desc"):
        return
    style = inherit(style, el)
    for k in ("opacity", "fill-opacity", "stroke-opacity"):
        if k in el.attrib:
            style[k] = float(style.get(k, 1.0)) * float(el.attrib[k])
    m = multiply(m, parse_transform(el.attrib.get("transform")))
    mask_ref = re.match(r"url\(#([^)]+)\)", el.attrib.get("mask", ""))
    if mask_ref and (out or in_mask):
        # A clear layer erases everything drawn before it, so a masked element must come first.
        raise ValueError("a masked element must be the first drawn content")
    if tag in ("svg", "g"):
        for child in el:
            walk(child, style, m, masks, out, root_style, in_mask)
    else:
        emit(el, tag, style, m, out, in_mask)
    if mask_ref:
        mask = masks[mask_ref.group(1)]
        # Mask content inherits from the mask's own ancestors (the root), in the user space of the
        # element that references it.
        base = inherit(root_style, mask)
        for child in mask:
            walk(child, base, m, masks, out, root_style, in_mask=True)


def emit(el, tag, style, m, out, in_mask):
    segs = transformed(geometry(el, tag), m)
    d = serialize(segs)
    accent = "accent" in style.get("class", "")
    fill, stroke = color_kind(style.get("fill", "black")), color_kind(style.get("stroke"))
    if not in_mask and "white" in (fill, stroke):
        raise ValueError("white paint outside a mask would draw as ink")
    width = float(style.get("stroke-width", 1)) * scale_of(m)
    common = {}
    if not in_mask:
        alpha = float(style.get("opacity", 1.0))
        if alpha < 1:
            common["alpha"] = round(alpha, 3)
    if accent or fill == "accent" or stroke == "accent":
        common["accent"] = True
    if fill and not (in_mask and fill == "white"):
        layer = {"d": d, "op": "clearFill" if in_mask else "fill", **common}
        a = float(style.get("fill-opacity", 1.0))
        if a < 1 and not in_mask:
            layer["alpha"] = round(a * layer.get("alpha", 1.0), 3)
        out.append(layer)
    if stroke and not (in_mask and stroke == "white"):
        layer = {"d": d, "op": "clearStroke" if in_mask else "stroke", "w": round(width, 3), **common}
        a = float(style.get("stroke-opacity", 1.0))
        if a < 1 and not in_mask:
            layer["alpha"] = round(a * layer.get("alpha", 1.0), 3)
        cap, join = style.get("stroke-linecap", "butt"), style.get("stroke-linejoin", "miter")
        if cap != "round":
            layer["cap"] = cap
        if join != "round":
            layer["join"] = join
        dash = el.attrib.get("stroke-dasharray")
        if dash and dash != "none":
            values = [float(v) for v in NUM.findall(dash)]
            factor = scale_of(m)
            if "pathLength" in el.attrib:
                factor = length(segs) / float(el.attrib["pathLength"])
            layer["dash"] = [round(v * factor, 3) for v in values]
            # pathLength scales the offset too (SVG 2). Lengths are exact here; Chrome's differ by a
            # few percent on rounded rects, so its dashes drift around the frame.
            phase = float(el.attrib.get("stroke-dashoffset", 0)) * factor
            if phase:
                layer["dashPhase"] = round(phase, 3)
        out.append(layer)


def layers(svg):
    root = ET.fromstring(svg)
    masks = {el.attrib["id"]: el for el in root.iter() if el.tag.split("}")[-1] == "mask"}
    out = []
    # SVG defaults: fill black, no stroke. Root attributes override through walk().
    walk(root, {"fill": "black"}, IDENTITY, masks, out, inherit({"fill": "black"}, root))
    return out


# MARK: Catalog


def sf_fallback(icon):
    for value in icon.get("replaces") or []:
        if re.fullmatch(r"[a-z0-9]+(\.[a-z0-9]+)*", value):
            return value
    return "questionmark.square.dashed"


def swift_member(name):
    parts = re.split(r"[.\-_]", name)
    member = parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])
    return f"`{member}`" if member in ("default", "repeat", "return", "import", "extension", "protocol", "case") else member


def build():
    icons, catalog = {}, []
    for path in sorted(SOURCE.glob("*.json")):
        for icon in json.loads(path.read_text())["icons"]:
            name = icon["name"]
            if name in icons:
                raise ValueError(f"duplicate icon {name}")
            drawing = {"line": layers(icon["line"]), "solid": layers(icon["solid"])}
            if icon.get("cat"):
                drawing["cat"] = layers(icon["cat"])
            icons[name] = drawing
            entry = {"name": name, "meaning": icon["meaning"], "sf": sf_fallback(icon), "family": name.rsplit(".", 1)[0]}
            if DENSE_SOLID.search(name):
                entry["denseStyle"] = "solid"
            catalog.append(entry)
    pack = {"id": "cmux", "version": 1, "grid": 24, "icons": dict(sorted(icons.items()))}
    catalog.sort(key=lambda e: e["name"])
    header = "// Generated by scripts/icons/build_pack.py from design/icons/source. Do not edit.\n\n"
    members = "\n".join(f"    nonisolated public static let {swift_member(e['name'])} = IconName(\"{e['name']}\")" for e in catalog)
    swift = header + "extension IconName {\n" + members + "\n}\n"
    catalog_swift = (header + "extension IconName {\n"
                     "    /// Every catalog name, in name order.\n"
                     "    nonisolated public static let catalog: [IconName] = [\n"
                     + "\n".join(f"        .{swift_member(e['name'])}," for e in catalog).rstrip(",") + "\n    ]\n}\n")
    pack_text = json.dumps(pack, separators=(",", ":"), ensure_ascii=False) + "\n"
    return {
        "pack_native": pack_text,
        "pack_web": pack_text,
        "catalog_native": json.dumps({"icons": catalog}, indent=1, ensure_ascii=False) + "\n",
        "names_swift": swift,
        "catalog_swift": catalog_swift,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail when an output is out of date")
    args = parser.parse_args()
    outputs = build()
    stale = []
    for key, text in outputs.items():
        path = OUTPUTS[key]
        if args.check:
            if not path.exists() or path.read_text() != text:
                stale.append(str(path.relative_to(REPO)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
    if stale:
        print("icon pack out of date; run scripts/icons/build_pack.py:\n  " + "\n  ".join(stale), file=sys.stderr)
        return 1
    if not args.check:
        print(f"{len(json.loads(outputs['pack_native'])['icons'])} icons -> " + ", ".join(str(p.relative_to(REPO)) for p in OUTPUTS.values()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
