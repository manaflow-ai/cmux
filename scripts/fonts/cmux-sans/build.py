#!/usr/bin/env python3
"""Builds cmux Sans, the cmux typeface, from Source Sans 3 (SIL OFL 1.1, Reserved Font Name "Source").

Leo, 2026-11-05: "I'm actually saying we should make our own font." The font study (webviews/src/gallery/fontStudy)
picked Source Sans 3 as the base: densest, calm, humanist. Its one fault at UI sizes is a small x-height (478 of
1000, against Inter's 546), so at the same pixel size it reads a size smaller. This build keeps its outlines and
spacing and changes three things, each a parameter of a preset:

- the optical size (`scale`): every outline and metric grows by this factor at the same em, so 12 px text
  draws as Source Sans 3 would at 12 px times `scale`;
- the x-height (`xheight`): lowercase letters are stretched between the baseline and the x-height to this
  height, and from there to the ascender, so ascenders, descenders and capitals keep their heights; marks over
  lowercase letters (composite accents and the GPOS mark anchors) move up with them;
- the name: the OFL reserves "Source", so the family is "cmux Sans" and the copyright line names both.

Spacing at each UI size is the type scale's tracking table, not the font's (candidates.ts, `tracking`).

Every weight master moves with the default: the build computes each master's outline (the default plus its
deltas), maps it, and solves the deltas again with fontTools' VariationModel, so the variable font interpolates
as before.

Needs fontTools and brotli. Usage:
    build.py --preset b --out DIR          one preset, writes cmuxSans-PRESET[wght].ttf and .woff2
    build.py --all --out DIR               every preset
    build.py --all --out DIR --subset latin  the gallery's Latin subset (study files)
The source zip is fetched once into ~/.cache/cmux-sans and checked against its sha256.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import unicodedata
import urllib.request
import zipfile
from pathlib import Path

from fontTools.misc.fixedTools import otRound
from fontTools.ttLib import TTFont
from fontTools.ttLib.scaleUpem import scale_upem
from fontTools.ttLib.tables.TupleVariation import TupleVariation
from fontTools.ttLib.tables._g_l_y_f import GlyphCoordinates
from fontTools.varLib.models import VariationModel, supportScalar

SOURCE_URL = "https://github.com/adobe-fonts/source-sans/releases/download/3.052R/VF-source-sans-3.052R.zip"
SOURCE_SHA256 = "d8e2ac355e06e6a0f0e0a0b1ac0c2451afa707584d7bb9d6b11ef9e4b749904c"
SOURCE_MEMBER = "VF/SourceSans3VF-Upright.ttf"

FAMILY = "cmux Sans"
PS_FAMILY = "cmuxSans"
COPYRIGHT = (
    "Copyright 2010-2022 Adobe (http://www.adobe.com/), with Reserved Font Name 'Source'. "
    "Modifications copyright 2026 Manaflow, Inc. (cmux Sans)."
)
DESCRIPTION = (
    "cmux Sans is a modified version of Source Sans 3 by Adobe: a larger optical size and a taller "
    "x-height for small interface text. It is not Source Sans and is not endorsed by Adobe."
)

# x-height in the source's units (478), before `scale`. Scale is the optical-size factor.
PRESETS: dict[str, dict[str, float]] = {
    "a": {"scale": 1.083, "xheight": 478},  # the literal +1 px at 12 px, outlines as drawn
    "b": {"scale": 1.04, "xheight": 502},  # half a pixel larger, x-height +5 %
    "c": {"scale": 1.0, "xheight": 516},  # Source's size, x-height +8 %
}

# Glyph-name suffixes of lowercase forms that do not sit on the x-height.
NOT_ON_X_HEIGHT = (".sc", ".sups", ".subs", ".sinf", ".numr", ".dnom", "superior", "inferior")


def source_font() -> TTFont:
    cache = Path.home() / ".cache" / "cmux-sans" / SOURCE_URL.rsplit("/", 1)[1]
    if not cache.exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(SOURCE_URL) as response:
            cache.write_bytes(response.read())
    data = cache.read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
        raise SystemExit(f"{cache}: sha256 does not match {SOURCE_SHA256}")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        return TTFont(io.BytesIO(archive.read(SOURCE_MEMBER)))


def lowercase_glyphs(font: TTFont) -> set[str]:
    """Lowercase letters (Unicode Ll) and their alternates, except the small caps and figures-height forms."""
    base = {name for code, name in font.getBestCmap().items() if unicodedata.category(chr(code)) == "Ll"}
    found = set()
    for name in font.getGlyphOrder():
        if name.endswith(NOT_ON_X_HEIGHT) or any(part in name for part in NOT_ON_X_HEIGHT):
            continue
        if name in base or name.split(".", 1)[0] in base:
            found.add(name)
    return found


def height_map(x_height: float, target: float, ascender: float):
    """y to y: [0, x-height] stretches to [0, target], [x-height, ascender] to [target, ascender]; else unchanged."""

    def f(y: float) -> float:
        if 0 < y <= x_height:
            return y * target / x_height
        if x_height < y < ascender:
            return target + (y - x_height) * (ascender - target) / (ascender - x_height)
        return y

    return f


def remap_simple_glyph(font: TTFont, name: str, f) -> None:
    """Maps the glyph's points with f at the default and at every master, then solves its deltas again."""
    glyf, gvar = font["glyf"], font["gvar"]
    glyph = glyf[name]
    coords, controls = glyf._getCoordinatesAndControls(name, font["hmtx"].metrics, None)
    end_pts = controls[1]
    n_real = len(coords) - 4  # four phantom points close the list
    variations = gvar.variations.get(name, [])
    full = []
    for variation in variations:
        deltas = variation.coordinates
        if None in deltas:
            variation.calcInferredDeltas(coords, end_pts)
        full.append(variation)
    peaks = []
    for variation in full:
        peak = {tag: values[1] for tag, values in variation.axes.items()}
        if peak not in peaks:
            peaks.append(peak)
    locations = [{}] + peaks

    def at(location) -> GlyphCoordinates:
        points = GlyphCoordinates(coords)
        for variation in full:
            scalar = supportScalar(location, variation.axes)
            if scalar:
                points += GlyphCoordinates(variation.coordinates) * scalar
        return points

    def mapped(points: GlyphCoordinates) -> GlyphCoordinates:
        out = GlyphCoordinates(points)
        for i in range(n_real):
            x, y = out[i]
            out[i] = (x, f(y))
        return out

    masters = [mapped(at(location)) for location in locations]
    default = masters[0]
    glyph.coordinates = GlyphCoordinates([(otRound(x), otRound(y)) for x, y in list(default)[:n_real]])
    if not full:
        return
    model = VariationModel(locations, axisOrder=[axis.axisTag for axis in font["fvar"].axes])
    deltas = model.getDeltas(masters)
    rounded = GlyphCoordinates([(otRound(x), otRound(y)) for x, y in default])
    new = []
    for support, delta in zip(model.supports[1:], deltas[1:]):
        variation = TupleVariation(support, [(otRound(x), otRound(y)) for x, y in delta])
        variation.optimize(rounded, end_pts, tolerance=0.5)
        new.append(variation)
    gvar.variations[name] = new
    glyph.recalcBounds(glyf)


def raise_x_height(font: TTFont, target: float) -> None:
    glyf = font["glyf"]
    cmap = font.getBestCmap()
    x_height = font["OS/2"].sxHeight
    if target == x_height:
        return
    ascender = max(glyf[cmap[ord(c)]].yMax for c in "bdhkl")
    f = height_map(x_height, target, ascender)
    lowercase = lowercase_glyphs(font)
    shift = otRound(target - x_height)
    for name in sorted(lowercase):
        if not glyf[name].isComposite():
            remap_simple_glyph(font, name, f)
    # Composites built on a lowercase letter: the base moved with its letter; marks above it move up.
    for name in glyf.keys():
        glyph = glyf[name]
        if not glyph.isComposite() or glyph.components[0].glyphName not in lowercase:
            continue
        for component in glyph.components[1:]:
            mark = glyf[component.glyphName]
            mark.recalcBounds(glyf)
            if mark.numberOfContours and mark.yMin + component.y > x_height * 0.6:
                component.y += shift
        glyph.recalcBounds(glyf)
    # Marks typed after a lowercase letter attach at its base anchors.
    for lookup in font["GPOS"].table.LookupList.Lookup:
        for table in lookup.SubTable:
            table = table.ExtSubTable if lookup.LookupType == 9 else table
            if getattr(table, "LookupType", lookup.LookupType) != 4:
                continue
            for base, record in zip(table.BaseCoverage.glyphs, table.BaseArray.BaseRecord):
                if base not in lowercase:
                    continue
                for anchor in record.BaseAnchor:
                    if anchor is not None and anchor.YCoordinate > x_height * 0.6:
                        anchor.YCoordinate += shift
    font["OS/2"].sxHeight = otRound(target)


def rename(font: TTFont, preset: str | None) -> None:
    family = FAMILY if preset is None else f"{FAMILY} {preset.upper()}"
    ps = PS_FAMILY if preset is None else f"{PS_FAMILY}{preset.upper()}"
    names = font["name"]
    for record in list(names.names):
        text = record.toUnicode()
        if record.nameID in (1, 16):
            names.setName(family, record.nameID, record.platformID, record.platEncID, record.langID)
        elif record.nameID == 0:
            names.setName(COPYRIGHT, 0, record.platformID, record.platEncID, record.langID)
        elif record.nameID in (3, 4, 6, 25) or "Source" in text:
            replaced = (
                text.replace("SourceSans3VF", ps)
                .replace("SourceSans3", ps)
                .replace("Source Sans 3 VF", family)
                .replace("Source Sans 3", family)
                .replace("ADBO;", "CMUX;")
            )
            if "Source" in replaced and record.nameID not in (0, 7, 13):
                raise SystemExit(f"name {record.nameID} still says Source: {replaced!r}")
            names.setName(replaced, record.nameID, record.platformID, record.platEncID, record.langID)
    for record in list(names.names):
        if record.nameID in (8, 9, 11, 12):  # vendor and designer are Adobe's; this build is not theirs
            names.removeNames(nameID=record.nameID)
    names.setName(DESCRIPTION, 10, 3, 1, 0x409)
    names.setName(ps, 25, 3, 1, 0x409)
    font["OS/2"].achVendID = "CMUX"
    if "DSIG" in font:
        del font["DSIG"]


def build(preset: str, subset: str | None, out: Path, release: bool) -> list[Path]:
    params = PRESETS[preset]
    font = source_font()
    raise_x_height(font, params["xheight"])
    if params["scale"] != 1:
        scale_upem(font, otRound(1000 * params["scale"]))
        font["head"].unitsPerEm = 1000
    rename(font, None if release else preset)
    if subset == "latin":
        from fontTools import subset as fsubset

        options = fsubset.Options()
        options.layout_features = ["*"]
        options.name_IDs = ["*"]
        options.notdef_outline = True
        subsetter = fsubset.Subsetter(options)
        subsetter.populate(
            unicodes=list(range(0x20, 0x250)) + list(range(0x2000, 0x2070)) + [0x20AC, 0x2122, 0x2190, 0x2192, 0x2212]
        )
        subsetter.subset(font)
    stem = f"{PS_FAMILY}{'' if release else '-' + preset}[wght]"
    out.mkdir(parents=True, exist_ok=True)
    written = []
    ttf = out / f"{stem}.ttf"
    font.flavor = None
    font.save(ttf)
    written.append(ttf)
    font.flavor = "woff2"
    woff2 = out / f"{stem}.woff2"
    font.save(woff2)
    written.append(woff2)
    return written


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    which = parser.add_mutually_exclusive_group(required=True)
    which.add_argument("--preset", choices=sorted(PRESETS))
    which.add_argument("--all", action="store_true")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--subset", choices=["latin"])
    parser.add_argument("--release", action="store_true", help="name the family cmux Sans, without the preset")
    args = parser.parse_args()
    for preset in sorted(PRESETS) if args.all else [args.preset]:
        for path in build(preset, args.subset, args.out, args.release):
            print(f"{path} {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
