#!/usr/bin/env python3
"""Write the Swift and web copies of the static status glyphs (Leo 2026-10-14: the Static status mode),
every set of them (hq#1957 status glyph thunderdome: the default set and its competitors).

The one source is schemas/status-glyphs/static-status.json. This script writes the app's
(CmuxNextDesign/StatusIndicator/StaticStatusGlyph.generated.swift: CGPaths) and the webviews'
(webviews/src/ui/statusGlyphs.generated.ts: SVG path data), so a shape changes in one place for both.

    python3 scripts/cmux-next/gen-status-glyphs.py           # write the copies
    python3 scripts/cmux-next/gen-status-glyphs.py --check   # exit 1 when a copy drifted
"""
import json, math, os, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SOURCE = "schemas/status-glyphs/static-status.json"
SWIFT_FILE = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/StatusIndicator/StaticStatusGlyph.generated.swift"
TS_FILE = "webviews/src/ui/statusGlyphs.generated.ts"
ARITY = {"M": 2, "L": 2, "C": 6, "arc": 5, "circle": 3, "rect": 4, "Z": 0}


def load():
    with open(os.path.join(ROOT, SOURCE)) as handle:
        data = json.load(handle)
    sets = [glyph_set["name"] for glyph_set in data["sets"]]
    assert sets and len(sets) == len(set(sets)), "one set per name"
    first = data["sets"][0]["glyphs"]
    for glyph_set in data["sets"]:
        assert set(glyph_set) == {"name", "for", "glyphs"}, glyph_set["name"]
        glyphs = glyph_set["glyphs"]
        # Every set draws the same states in the same order, each with the same theme role: a set
        # changes shapes only, so the switch between sets never changes what a color means.
        assert [g["name"] for g in glyphs] == [g["name"] for g in first], glyph_set["name"]
        assert [g["tint"] for g in glyphs] == [g["tint"] for g in first], glyph_set["name"]
        for glyph in glyphs:
            where = (glyph_set["name"], glyph["name"])
            assert set(glyph) == {"name", "for", "tint", "master", "x1art"}, where
            assert glyph["tint"] in data["tints"], where
            art = glyph["x1art"]
            assert len(art) == 10 and all(len(row) == 10 and set(row) <= {".", "#"} for row in art), where
            for op in glyph["master"]:
                assert op[0] in ARITY and op[0] != "rect" and len(op) == ARITY[op[0]] + 1, (where, op)
            glyph["x1"] = pixel_rects(art)
    data["glyphs"] = first
    return data


def pixel_rects(art):
    """The ink of a pixel picture as rects: each row's runs, a run stacked on the same run above merged."""
    rects = []
    for y, row in enumerate(art):
        x = 0
        while x < len(row):
            if row[x] != "#":
                x += 1
                continue
            start = x
            while x < len(row) and row[x] == "#":
                x += 1
            above = next((r for r in rects if r[1] == start and r[3] == x - start and r[2] + r[4] == y), None)
            if above:
                above[4] += 1
            else:
                rects.append(["rect", start, y, x - start, 1])
    return rects


def num(value):
    return ("%.3f" % value).rstrip("0").rstrip(".") if value != int(value) else str(int(value))


def svg(ops):
    """SVG path data for `ops`, y-down like the source."""
    out, at = [], None
    for op in ops:
        kind, args = op[0], op[1:]
        if kind in ("M", "L"):
            out.append("%s%s %s" % (kind, num(args[0]), num(args[1])))
            at = (args[0], args[1])
        elif kind == "C":
            out.append("C" + " ".join(num(v) for v in args))
            at = (args[4], args[5])
        elif kind == "Z":
            out.append("Z")
        elif kind == "rect":
            x, y, w, h = args
            out.append("M%s %sh%sv%sh-%sZ" % (num(x), num(y), num(w), num(h), num(w)))
        elif kind == "circle":
            cx, cy, r = args
            out.append("M%s %sA%s %s 0 1 0 %s %sA%s %s 0 1 0 %s %sZ" % (
                num(cx - r), num(cy), num(r), num(r), num(cx + r), num(cy), num(r), num(r), num(cx - r), num(cy)))
        elif kind == "arc":
            cx, cy, r, start, end = args
            sx, sy = cx + r * math.cos(math.radians(start)), cy + r * math.sin(math.radians(start))
            ex, ey = cx + r * math.cos(math.radians(end)), cy + r * math.sin(math.radians(end))
            if at is None or abs(at[0] - sx) > 1e-6 or abs(at[1] - sy) > 1e-6:
                out.append("L%s %s" % (num(sx), num(sy)))
            large = 1 if abs(end - start) > 180 else 0
            sweep = 1 if end > start else 0
            out.append("A%s %s 0 %d %d %s %s" % (num(r), num(r), large, sweep, num(ex), num(ey)))
            at = (ex, ey)
    return "".join(out)


def swift_ops(ops):
    lines = []
    for op in ops:
        kind, args = op[0], [num(float(v)) for v in op[1:]]
        if kind == "M":
            lines.append("path.move(to: CGPoint(x: %s, y: %s))" % tuple(args))
        elif kind == "L":
            lines.append("path.addLine(to: CGPoint(x: %s, y: %s))" % tuple(args))
        elif kind == "C":
            lines.append("path.addCurve(to: CGPoint(x: %s, y: %s), control1: CGPoint(x: %s, y: %s), control2: CGPoint(x: %s, y: %s))"
                         % (args[4], args[5], args[0], args[1], args[2], args[3]))
        elif kind == "Z":
            lines.append("path.closeSubpath()")
        elif kind == "rect":
            lines.append("path.addRect(CGRect(x: %s, y: %s, width: %s, height: %s))" % tuple(args))
        elif kind == "circle":
            cx, cy, r = (float(v) for v in op[1:])
            lines.append("path.addEllipse(in: CGRect(x: %s, y: %s, width: %s, height: %s))"
                         % (num(cx - r), num(cy - r), num(2 * r), num(2 * r)))
        elif kind == "arc":
            cx, cy, r, start, end = op[1:]
            # The grid runs y-down, so a growing angle turns clockwise on screen, which CG (y-up) calls
            # counterclockwise: `clockwise` is true when the angle shrinks.
            lines.append("path.addArc(center: CGPoint(x: %s, y: %s), radius: %s, startAngle: %s, endAngle: %s, clockwise: %s)"
                         % (num(float(cx)), num(float(cy)), num(float(r)), angle(start), angle(end), "true" if end < start else "false"))
    return "\n".join("            " + line for line in lines)


def angle(degrees):
    if degrees == 0:
        return "0"
    return "%s.pi%s" % ("-" if degrees < 0 else "", "" if abs(degrees) == 180 else " * %s" % num(abs(degrees) / 180))


def swift_doc(text):
    return text[0].upper() + text[1:]


def swift(data):
    cases = "\n".join("    /// %s.\n    case %s" % (swift_doc(g["for"]), g["name"]) for g in data["glyphs"])
    tints = "\n".join("        case .%s: .%s" % (g["name"], data["tints"][g["tint"]]["swift"]) for g in data["glyphs"])
    styles = "\n".join("        /// %s\n        case %s" % (s["for"], s["name"]) for s in data["sets"])
    paths = "\n".join(
        "        case (.%s, .%s, %s):\n%s" % (s["name"], g["name"], "true" if grid == "x1" else "false", swift_ops(g[grid]))
        for s in data["sets"] for g in s["glyphs"] for grid in ("master", "x1"))
    return """// GENERATED by scripts/cmux-next/gen-status-glyphs.py from
// {src}. Do not edit; edit the JSON and rerun.

public import CoreGraphics

/// The static status glyphs (Leo 2026-10-14, the Static status mode): one shape per state, told apart
/// by shape alone at 10 pt, never animated, tinted by a theme role. The webviews draw the same paths
/// (`webviews/src/ui/statusGlyphs.generated.ts`).
public nonisolated enum StaticStatusGlyph: String, CaseIterable, Hashable, Sendable {{
{cases}

    /// A set of shapes for the six states (hq#1957 status glyph thunderdome). Every set keeps each
    /// state's theme role; `{default}` is the default.
    public enum Style: String, CaseIterable, Hashable, Sendable {{
{styles}
    }}

    /// The theme role the glyph is tinted with, the same in every style.
    public var tint: StatusIndicatorPlan.Tint {{
        switch self {{
{tints}
        }}
    }}

    /// Whether a square of `pixels` takes the 1x-hinted drawing: its pixel grid is the hinted 10-unit
    /// grid's (10 pt at 1x), not the master's 20 (10 pt at 2x).
    public static func usesHinting(pixels: CGFloat) -> Bool {{
        pixels.rounded() == pixels && pixels.truncatingRemainder(dividingBy: 20) == 10
    }}

    /// The glyph in `style` filling `rect` (y-up, as CG draws), to fill with the even-odd rule.
    public func path(in rect: CGRect, style: Style = .{default}) -> CGPath {{
        let hinted = Self.usesHinting(pixels: rect.width)
        let grid: CGFloat = hinted ? 10 : 20
        let path = CGMutablePath()
        switch (style, self, hinted) {{
{paths}
        }}
        // The grid runs y-down from the top-left corner.
        var place = CGAffineTransform(a: rect.width / grid, b: 0, c: 0, d: -rect.height / grid, tx: rect.minX, ty: rect.maxY)
        return path.copy(using: &place) ?? path
    }}
}}
""".format(src=SOURCE, cases=cases, tints=tints, styles=styles, default=data["sets"][0]["name"], paths=paths)


def field(key, value, indent):
    """One `key: "value",` line, wrapped as the formatter (vp: 120 columns) wraps a long one: never after
    a short key (narrower than the 2-column tab plus 3, as Prettier's `isObjectPropertyWithShortKey`)."""
    pad = " " * indent
    line = "%s%s: %s," % (pad, key, json.dumps(value))
    return line if len(line) <= 120 or len(key) < 5 else "%s%s:\n%s  %s," % (pad, key, pad, json.dumps(value))


def ts(data):
    sets = []
    for s in data["sets"]:
        rows = []
        for g in s["glyphs"]:
            fields = [("for", g["for"]), ("tint", data["tints"][g["tint"]]["css"]), ("master", svg(g["master"])), ("x1", svg(g["x1"]))]
            rows.append("      %s: {\n%s\n      }," % (g["name"], "\n".join(field(key, value, 8) for key, value in fields)))
        sets.append("  %s: {\n%s\n    glyphs: {\n%s\n    },\n  }," % (s["name"], field("for", s["for"], 4), "\n".join(rows)))
    return """// GENERATED by scripts/cmux-next/gen-status-glyphs.py from {src}.
// Do not edit; edit the JSON and rerun. The app draws the same paths (StaticStatusGlyph.generated.swift).

/** One static status glyph: SVG path data on the master 20-unit grid (10 px at 2x) and on the 10-unit
 * grid hinted for 1x, both filled even-odd, and the theme color it is tinted with. */
export type StatusGlyphArt = {{ for: string; tint: string; master: string; x1: string }};

/** The glyph sets (hq#1957 status glyph thunderdome): each draws the same states with the same tints. */
export const STATUS_GLYPH_SETS = {{
{sets}
}} as const satisfies Record<string, {{ for: string; glyphs: Record<string, StatusGlyphArt> }}>;

export type StatusGlyphSetName = keyof typeof STATUS_GLYPH_SETS;

/** The default set, the app's `StaticStatusGlyph.Style.{default}`. */
export const DEFAULT_STATUS_GLYPH_SET = "{default}" satisfies StatusGlyphSetName;

export const STATUS_GLYPHS = STATUS_GLYPH_SETS[DEFAULT_STATUS_GLYPH_SET].glyphs;

export type StatusGlyphName = keyof typeof STATUS_GLYPHS;
""".format(src=SOURCE, sets="\n".join(sets), default=data["sets"][0]["name"])


def main():
    check = "--check" in sys.argv[1:]
    data = load()
    wanted = {SWIFT_FILE: swift(data), TS_FILE: ts(data)}
    drifted = []
    for path, text in wanted.items():
        full = os.path.join(ROOT, path)
        old = open(full).read() if os.path.exists(full) else None
        if old == text:
            continue
        if check:
            drifted.append(path)
        else:
            with open(full, "w") as handle:
                handle.write(text)
            print("wrote " + path)
    if drifted:
        print("status glyph copies drifted from %s: %s\nrun python3 scripts/cmux-next/gen-status-glyphs.py" % (SOURCE, ", ".join(drifted)))
        sys.exit(1)


if __name__ == "__main__":
    main()
