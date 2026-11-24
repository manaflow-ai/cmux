"""The family's shared vertical table, applied to a face: cap height, x-height, ascender, descender, tracking.

hq docs/research/2026-11-19-our-own-type-family.md ("one shared table that the three builds read"):
capitals reach the family's cap height by a uniform scale (Sans, Serif) or a vertical one (Mono, whose 600
advance must stay); lowercase is mapped, baseline to x-height, x-height to ascender, and below the baseline,
onto the family's x-height, ascender and descender. Every weight and optical-size master is mapped with its
own measured heights, so the x-height is the same at every location of every axis (the doc: "The x-height
stays 530 at every optical size"), and the deltas are solved again so the font still interpolates (the
cmux Sans method, scripts/fonts/cmux-sans/build.py).
"""

from __future__ import annotations

import unicodedata
from collections.abc import Callable

from fontTools.misc.fixedTools import otRound
from fontTools.pens.boundsPen import BoundsPen
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables.TupleVariation import TupleVariation
from fontTools.ttLib.tables._g_l_y_f import GlyphCoordinates
from fontTools.varLib.models import VariationModel, supportScalar

Map = Callable[[float], float]
NOT_ON_X_HEIGHT = (".sc", ".sups", ".subs", ".sinf", ".numr", ".dnom", "superior", "inferior")


def axis_order(font: TTFont) -> list[str]:
    return [axis.axisTag for axis in font["fvar"].axes] if "fvar" in font else []


def remap_glyph(font: TTFont, name: str, f_at: Callable[[dict], Map]) -> None:
    """Maps the glyph's y coordinates with `f_at(location)` at the default and at every master location,
    then solves its deltas again. Phantom points keep their values."""
    glyf = font["glyf"]
    glyph = glyf[name]
    if glyph.isComposite() or glyph.numberOfContours <= 0:
        return
    coords, controls = glyf._getCoordinatesAndControls(name, font["hmtx"].metrics, None)
    end_pts = controls[1]
    n_real = len(coords) - 4
    variations = font["gvar"].variations.get(name, []) if "gvar" in font else []
    for variation in variations:
        if None in variation.coordinates:
            variation.calcInferredDeltas(coords, end_pts)
    locations: list[dict] = [{}]
    for variation in variations:
        peak = {tag: values[1] for tag, values in variation.axes.items()}
        if peak not in locations:
            locations.append(peak)

    def at(location: dict) -> GlyphCoordinates:
        points = GlyphCoordinates(coords)
        for variation in variations:
            scalar = supportScalar(location, variation.axes)
            if scalar:
                points += GlyphCoordinates(variation.coordinates) * scalar
        return points

    masters = []
    for location in locations:
        points = at(location)
        f = f_at(location)
        for i in range(n_real):
            x, y = points[i]
            points[i] = (x, f(y))
        masters.append(points)
    default = masters[0]
    glyph.coordinates = GlyphCoordinates([(otRound(x), otRound(y)) for x, y in list(default)[:n_real]])
    if variations:
        model = VariationModel(locations, axisOrder=axis_order(font))
        deltas = model.getDeltas(masters)
        rounded = GlyphCoordinates([(otRound(x), otRound(y)) for x, y in default])
        new = []
        for support, delta in zip(model.supports[1:], deltas[1:]):
            variation = TupleVariation(support, [(otRound(x), otRound(y)) for x, y in delta])
            variation.optimize(rounded, end_pts, tolerance=0.5)
            new.append(variation)
        font["gvar"].variations[name] = new
    glyph.recalcBounds(glyf)


class Heights:
    """A face's heights at any location: cap (H), x-height (x), ascender (d), descender (p), measured from
    the outlines, cached per location."""

    def __init__(self, font: TTFont):
        self.font = font
        self.cmap = font.getBestCmap()
        self.cache: dict[tuple, dict] = {}

    def at(self, location: dict) -> dict:
        key = tuple(sorted(location.items()))
        if key not in self.cache:
            # Master locations are gvar's own (normalized, after avar), which getGlyphSet takes as is.
            glyphs = self.font.getGlyphSet(location=location or None, normalized=True)

            def bounds(char: str):
                pen = BoundsPen(glyphs)
                glyphs[self.cmap[ord(char)]].draw(pen)
                return pen.bounds

            self.cache[key] = {
                "cap": bounds("H")[3],
                "x": bounds("x")[3],
                "asc": bounds("d")[3],
                "desc": bounds("p")[1],
            }
        return self.cache[key]



def lowercase_glyphs(font: TTFont) -> set[str]:
    base = {name for code, name in font.getBestCmap().items() if unicodedata.category(chr(code)) == "Ll"}
    return {
        name
        for name in font.getGlyphOrder()
        if not any(part in name for part in NOT_ON_X_HEIGHT) and (name in base or name.split(".", 1)[0] in base)
    }


def scale_vertical(font: TTFont, s: float) -> None:
    """Every glyph, mark anchor and vertical metric times `s` in y only; advances and x stay (the Mono)."""
    if s == 1:
        return
    for name in font.getGlyphOrder():
        remap_glyph(font, name, lambda _location: (lambda y: y * s))
        glyph = font["glyf"][name]
        if glyph.isComposite():
            for component in glyph.components:
                component.y = otRound(component.y * s)
    for anchor in anchors(font):
        anchor.YCoordinate = otRound(anchor.YCoordinate * s)
    os2 = font["OS/2"]
    for attr in ("sCapHeight", "sxHeight", "ySuperscriptYSize", "ySubscriptYSize", "ySuperscriptYOffset",
                 "ySubscriptYOffset", "yStrikeoutPosition"):
        if hasattr(os2, attr):
            setattr(os2, attr, otRound(getattr(os2, attr) * s))
    font["post"].underlinePosition = otRound(font["post"].underlinePosition * s)


def lowercase_map(heights: Heights, x: float, asc: float, desc: float) -> Callable[[dict], Map]:
    """f_at(location): baseline..x-height to 0..x, x-height..ascender to x..asc, below the baseline scaled
    so the descender lands on desc, above the ascender shifted with it."""

    def f_at(location: dict) -> Map:
        h = heights.at(location)
        sx, sa, sd = h["x"], h["asc"], h["desc"]

        def f(y: float) -> float:
            if y < 0:
                return y * desc / sd
            if y <= sx:
                return y * x / sx
            if y <= sa:
                return x + (y - sx) * (asc - x) / (sa - sx)
            return y + (asc - sa)

        return f

    return f_at


def set_lowercase(font: TTFont, x: float, asc: float, desc: float) -> None:
    heights = Heights(font)
    default = dict(heights.at({}))
    lowercase = lowercase_glyphs(font)
    # Measure every master location the lowercase uses before any outline moves (x, d and p are lowercase).
    if "gvar" in font:
        for name in lowercase:
            for variation in font["gvar"].variations.get(name, []):
                heights.at({tag: values[1] for tag, values in variation.axes.items()})
    f_at = lowercase_map(heights, x, asc, desc)
    for name in sorted(lowercase):
        remap_glyph(font, name, f_at)
    shift = otRound(x - default["x"])
    glyf = font["glyf"]
    # Composites on a lowercase letter: marks over the x-height ride up with it (cmux Sans's rule).
    for name in glyf.keys():
        glyph = glyf[name]
        if not glyph.isComposite() or glyph.components[0].glyphName not in lowercase:
            continue
        for component in glyph.components[1:]:
            mark = glyf[component.glyphName]
            mark.recalcBounds(glyf)
            if mark.numberOfContours and mark.yMin + component.y > default["x"] * 0.6:
                component.y += shift
        glyph.recalcBounds(glyf)
    f = f_at({})
    for base, anchor in base_anchors(font):
        if base in lowercase:
            anchor.YCoordinate = otRound(f(anchor.YCoordinate)) if anchor.YCoordinate < default["x"] * 0.6 else (
                anchor.YCoordinate + shift
            )
    font["OS/2"].sxHeight = otRound(x)


def match_cap(font: TTFont) -> float:
    return Heights(font).at({})["cap"]


def track(font: TTFont, units: int) -> None:
    """Adds `units` to every advance, half on each side: outlines and mark anchors move right by half."""
    if not units:
        return
    half = units / 2
    glyf, hmtx = font["glyf"], font["hmtx"]
    for name in font.getGlyphOrder():
        glyph = glyf[name]
        advance, lsb = hmtx[name]
        if advance == 0:
            continue  # combining marks keep their zero advance and their place
        if not glyph.isComposite() and glyph.numberOfContours > 0:
            glyph.coordinates.translate((otRound(half), 0))
            glyph.recalcBounds(glyf)
        elif glyph.isComposite():
            for component in glyph.components:
                if hmtx[component.glyphName][0] == 0:
                    component.x += otRound(half)  # a mark component did not move with its base
        hmtx[name] = (advance + units, lsb + otRound(half))
    for base, anchor in base_anchors(font):
        if hmtx[base][0] != 0:
            anchor.XCoordinate += otRound(half)


def anchors(font: TTFont):
    """Every Anchor in GPOS."""
    if "GPOS" not in font:
        return

    def walk(table, seen):
        if id(table) in seen or table is None:
            return
        seen.add(id(table))
        if type(table).__name__ == "Anchor":
            yield table
            return
        for value in vars(table).values() if hasattr(table, "__dict__") else []:
            items = value if isinstance(value, list) else [value]
            for item in items:
                if hasattr(item, "__dict__") and type(item).__module__.endswith("otTables"):
                    yield from walk(item, seen)

    yield from walk(font["GPOS"].table, set())


def base_anchors(font: TTFont):
    """(glyph, anchor) for every mark-to-base and mark-to-ligature base anchor and cursive anchor."""
    if "GPOS" not in font:
        return
    for lookup in font["GPOS"].table.LookupList.Lookup:
        for table in lookup.SubTable:
            kind = lookup.LookupType
            if kind == 9:
                kind, table = table.ExtensionLookupType, table.ExtSubTable
            if kind == 4:
                for base, record in zip(table.BaseCoverage.glyphs, table.BaseArray.BaseRecord):
                    for anchor in record.BaseAnchor:
                        if anchor is not None:
                            yield base, anchor
            elif kind == 3:
                for glyph, record in zip(table.Coverage.glyphs, table.EntryExitRecord):
                    for anchor in (record.EntryAnchor, record.ExitAnchor):
                        if anchor is not None:
                            yield glyph, anchor
