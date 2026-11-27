#!/usr/bin/env python3
"""Builds cmux Sans, the cmux typeface, from Source Sans 3 (SIL OFL 1.1, Reserved Font Name "Source").

Leo, 2026-11-05: "I'm actually saying we should make our own font." The font study (webviews/src/gallery/fontStudy)
picked Source Sans 3 as the base: densest, calm, humanist. Its one fault at UI sizes is a small x-height (478 of
1000, against Inter's 546), so at the same pixel size it reads a size smaller. This build keeps its outlines and
spacing and changes up to four things, each a parameter of a preset:

- the optical size (`scale`): every outline and metric grows by this factor at the same em, so 12 px text
  draws as Source Sans 3 would at 12 px times `scale`;
- the x-height (`xheight`): lowercase letters are stretched between the baseline and the x-height to this
  height, and from there to the ascender, so ascenders, descenders and capitals keep their heights; marks over
  lowercase letters (composite accents and the GPOS mark anchors) move up with them;
- the default forms (`sets`): Source's own alternates, such as the tailed l and the single-storey g, drawn
  without a feature;
- the name: the OFL reserves "Source", so the family is "cmux Sans" and the copyright line names both.

Spacing at each UI size is the type scale's tracking table, not the font's (candidates.ts, `tracking`).

Every weight master moves with the default: the build computes each master's outline (the default plus its
deltas), maps it, and solves the deltas again with fontTools' VariationModel, so the variable font interpolates
as before.

Needs fontTools and brotli. Usage:
    build.py --preset b --out DIR          one preset, writes cmuxSans-PRESET[wght].ttf and .woff2
    build.py --all --out DIR               every preset
    build.py --all --out DIR --subset latin  Fontsource's Latin subset (the gallery's and the chat's files)
    build.py --preset c --subset latin --release --out DIR   the chat's cmux Sans (family "cmux Sans")
    build.py --preset squat --subset latin --release --out DIR   cmux Sans Squat (likewise candy and open)
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

# x-height in the source's units (478), before `scale`. Scale is the optical-size factor. `sets` are Source's
# own stylistic sets made the default forms: ss05 is the tailed l (Il1 apart), ss04 the single-storey g.
# Round 3 dropped a +1 px optical size (scale 1.083): it cost the density that made Source win.
# The personality cuts (Leo, 2026-11-19: cmux Sans looks "a bit like generic school font ... It just doesn't have
# that like pizzazz"; he likes Folio's sans, Hanken Grotesk, for looking "a bit squat") add three parameters: `width`, every
# outline, advance and kern scaled horizontally by this factor; `weight`, the weight that draws at the CSS weight
# 400 (the whole axis shifts with it, 200 and 900 stay put); `name`, the family's suffix in a release build
# ("cmux Sans Squat"). ss02 is the single-storey a.
PRESETS: dict[str, dict] = {
    "b": {"scale": 1.04, "xheight": 502},  # half a pixel larger, x-height +5 %
    "c": {"scale": 1.0, "xheight": 516},  # Source's size, x-height +8 %
    "c-l": {"scale": 1.0, "xheight": 516, "sets": ["ss05"]},
    "c-g": {"scale": 1.0, "xheight": 516, "sets": ["ss04"]},
    "c-lg": {"scale": 1.0, "xheight": 516, "sets": ["ss05", "ss04"]},
    # Wide and low: a big lowercase in a short line, ascenders pulled toward it, a touch heavier.
    "squat": {"scale": 1.0, "xheight": 548, "width": 1.08, "weight": 440, "name": "Squat"},
    # Round and soft: the single-storey a, the tailed l, wider and heavier still.
    "candy": {"scale": 1.0, "xheight": 536, "width": 1.05, "weight": 470, "sets": ["ss02", "ss05"], "name": "Candy"},
    # Open: the fix is the fit, not the letters (Leo, 2026-11-19: "The kerning in cmux sans is off it all looks too
    # packed together and narrow a lot of the time ... Quillet does things better"). Measured against Quillet at
    # 400: its lowercase sidebearings sum 103 units to cmux Sans's 88, its o is 45 units wider, its word space 270 to
    # 200. So: 4 % wider, 8 units more on each side of a lowercase letter and 4 more right of the round ones (whose
    # right sides are the tight ones), 3 each side of a capital and 6 right of the round ones, 4 each side of a
    # figure, and a 255-unit word space. The x-height stays cmux Sans's: a taller one would crowd the line again.
    "open": {
        "scale": 1.0,
        "xheight": 516,
        "width": 1.04,
        "spacing": {
            "lower": (8, 8),
            "round_lower": 4,
            "upper": (3, 3),
            "round_upper": 6,
            "digit": (4, 4),
            "space": 255,
        },
        "name": "Open",
    },
}

# Fontsource's "latin" subset, the range every other bundled chat face is cut to (chatFonts/FONTS.md).
LATIN = [
    *range(0x00, 0x100), 0x131, 0x152, 0x153, 0x2BB, 0x2BC, 0x2C6, 0x2DA, 0x2DC, 0x304, 0x308, 0x329,
    *range(0x2000, 0x2070), 0x20AC, 0x2122, 0x2191, 0x2193, 0x2212, 0x2215, 0xFEFF, 0xFFFD,
]

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
        return TTFont(io.BytesIO(archive.read(SOURCE_MEMBER)), recalcTimestamp=False)  # reproducible files


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


def make_default(font: TTFont, sets: list[str]) -> None:
    """Points every character a stylistic set changes at the set's form, so the face draws it without the feature
    (natively too, where NSFont applies no feature). The plain form stays in the font for the other features."""
    gsub = font["GSUB"].table
    mapping: dict[str, str] = {}
    for record in gsub.FeatureList.FeatureRecord:
        if record.FeatureTag not in sets:
            continue
        for index in record.Feature.LookupListIndex:
            lookup = gsub.LookupList.Lookup[index]
            for table in lookup.SubTable:
                table = table.ExtSubTable if lookup.LookupType == 7 else table
                # One glyph to one: a cmap names one glyph, so a set's one-to-many rules (ss01's J̌) stay features.
                mapping.update({k: v for k, v in getattr(table, "mapping", {}).items() if isinstance(v, str)})
    if not mapping:
        raise SystemExit(f"no single substitutions in {sets}")
    for table in font["cmap"].tables:
        for code, name in list(table.cmap.items()):
            if name in mapping:
                table.cmap[code] = mapping[name]


def scale_width(font: TTFont, factor: float) -> None:
    """Scales every glyph, advance and horizontal position by `factor` at the default and every master. An x scale
    is linear, so each delta scales with its point; the kerns and mark anchors (GPOS) and the variation deltas
    they name scale too. HVAR goes: without it the advances vary by the glyphs' phantom points, which scaled."""
    glyf, gvar, hmtx = font["glyf"], font["gvar"], font["hmtx"]
    for name in font.getGlyphOrder():
        coords, _controls = glyf._getCoordinatesAndControls(name, hmtx.metrics, None)
        glyf._setCoordinates(name, GlyphCoordinates([(otRound(x * factor), y) for x, y in coords]), hmtx.metrics)
        for variation in gvar.variations.get(name, []):
            variation.coordinates = [
                None if delta is None else (otRound(delta[0] * factor), delta[1]) for delta in variation.coordinates
            ]
    del font["HVAR"]
    varied: set[int] = set()

    def walk(table, seen: set[int]) -> None:
        if table is None or id(table) in seen:
            return
        seen.add(id(table))
        if isinstance(table, list):
            for item in table:
                walk(item, seen)
            return
        if not hasattr(table, "__dict__"):
            return
        for field in ("XPlacement", "XAdvance", "XCoordinate"):
            if isinstance(getattr(table, field, None), int):
                setattr(table, field, otRound(getattr(table, field) * factor))
        for field in ("XPlaDevice", "XAdvDevice", "XDeviceTable"):
            device = getattr(table, field, None)
            if device is not None and getattr(device, "DeltaFormat", 0) == 0x8000:
                varied.add((device.StartSize << 16) + device.EndSize)
        for value in vars(table).values():
            if hasattr(value, "__dict__") or isinstance(value, list):
                walk(value, seen)

    walk(font["GPOS"].table, set())
    store = font["GDEF"].table.VarStore
    for index in varied:
        row = store.VarData[index >> 16].Item[index & 0xFFFF]
        row[:] = [otRound(delta * factor) for delta in row]
    font["OS/2"].recalcAvgCharWidth(font)


def shift_weight(font: TTFont, weight: float) -> None:
    """Makes the CSS weight 400 draw the axis's `weight`: avar maps each user weight through a line from (min,
    min) to (400, weight) to (max, max) before its own map, so the weights keep their order and 200 and 900 stay."""
    axis = next(axis for axis in font["fvar"].axes if axis.axisTag == "wght")
    span = axis.maxValue - axis.minValue  # the default is the minimum: the normalized axis runs 0 to 1
    regular, target = (400 - axis.minValue) / span, (weight - axis.minValue) / span
    segments = font["avar"].segments["wght"]
    old = sorted(segments.items())

    def through(points, x):
        for (x0, y0), (x1, y1) in zip(points, points[1:]):
            if x0 <= x <= x1:
                return y0 if x1 == x0 else y0 + (x - x0) * (y1 - y0) / (x1 - x0)
        return x

    shift = [(-1.0, -1.0), (0.0, 0.0), (regular, target), (1.0, 1.0)]
    unshift = [(y, x) for x, y in shift]
    # The composed map bends where the shift does and where the old map does (at the shift's inverse).
    breaks = {x for x, _ in shift} | {through(unshift, x) for x, _ in old}
    font["avar"].segments["wght"] = {x: through(old, through(shift, x)) for x in sorted(breaks)}


def add_space(font: TTFont, spacing: dict) -> None:
    """Opens the fit: each letter's sidebearings grow by the units its class gets (`lower`, `upper`, `digit`, each a
    (left, right) pair, plus `round_lower` and `round_upper` added on the right of the round letters, whose right
    sides are the tight ones), and the word space becomes `space` wide. A simple glyph's points move right by its
    left addition at the default; every master moves with it, so the deltas stay. A composite keeps its base's
    offset (the base moved) and moves its marks with it. Marks keep their zero width. The base anchors marks attach
    to (GPOS) move with their letter, so accents stay centred. Kerning is relative and stays."""
    glyf, hmtx, cmap = font["glyf"], font["hmtx"], font.getBestCmap()
    kind: dict[str, str] = {}
    for code, name in cmap.items():
        category = unicodedata.category(chr(code))
        kind[name] = {"Ll": "lower", "Lu": "upper", "Lt": "upper", "Lo": "lower", "Nd": "digit"}.get(category, "")
    for name in font.getGlyphOrder():  # alternates follow their base letter (a.a, g.a, l.a)
        if name not in kind and name.split(".", 1)[0] in kind:
            kind[name] = kind[name.split(".", 1)[0]]
    round_lower = {"o", "c", "e", "d", "q", "b", "p", "a.a"}
    round_upper = {"O", "C", "G", "D", "Q"}

    def amount(name: str) -> tuple[int, int]:
        cls = kind.get(name, "")
        if not cls:
            return 0, 0
        left, right = spacing.get(cls, (0, 0))
        if name in round_lower:
            right += spacing.get("round_lower", 0)
        if name in round_upper:
            right += spacing.get("round_upper", 0)
        return left, right

    moved: dict[str, int] = {}
    for name in font.getGlyphOrder():
        glyph = glyf[name]
        if glyph.isComposite():
            base = glyph.components[0].glyphName
            left, right = amount(name) if name in kind else amount(base)
            if (left, right) == (0, 0) and base not in moved:
                continue
            base_left = moved.get(base, amount(base)[0])
            for component in glyph.components[1:]:
                component.x += base_left  # marks move with the base the base glyph already shifted
            advance, lsb = hmtx[name]
            hmtx[name] = (advance + left + right, lsb + base_left)
            moved[name] = base_left
            continue
        left, right = amount(name)
        if (left, right) == (0, 0):
            continue
        coords, _controls = glyf._getCoordinatesAndControls(name, hmtx.metrics, None)
        n_real = len(coords) - 4
        shifted = [(x + left, y) for x, y in list(coords)[:n_real]]
        phantom = list(coords)[n_real:]
        phantom[1] = (phantom[1][0] + left + right, phantom[1][1])  # the right side
        glyf._setCoordinates(name, GlyphCoordinates(shifted + phantom), hmtx.metrics)
        moved[name] = left
    space = cmap.get(0x20)
    if space and spacing.get("space"):
        advance, lsb = hmtx[space]
        hmtx[space] = (spacing["space"], lsb)
    for lookup in font["GPOS"].table.LookupList.Lookup:
        for table in lookup.SubTable:
            table = table.ExtSubTable if lookup.LookupType == 9 else table
            if getattr(table, "LookupType", lookup.LookupType) != 4:
                continue
            for base, record in zip(table.BaseCoverage.glyphs, table.BaseArray.BaseRecord):
                for anchor in record.BaseAnchor:
                    if anchor is not None and moved.get(base):
                        anchor.XCoordinate += moved[base]
    font["OS/2"].recalcAvgCharWidth(font)


def rename(font: TTFont, suffix: str | None) -> None:
    family = FAMILY if suffix is None else f"{FAMILY} {suffix}"
    ps = PS_FAMILY if suffix is None else f"{PS_FAMILY}{suffix}"
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
    raise_x_height(font, params["xheight"])  # first, while the plain forms are still the ones the cmap names
    if params.get("sets"):
        make_default(font, params["sets"])
    if params["scale"] != 1:
        scale_upem(font, otRound(1000 * params["scale"]))
        font["head"].unitsPerEm = 1000
    if params.get("width", 1) != 1:
        scale_width(font, params["width"])
    if params.get("spacing"):
        add_space(font, params["spacing"])
    if params.get("weight", 400) != 400:
        shift_weight(font, params["weight"])
    suffix = params.get("name") if release else preset.upper()
    rename(font, suffix)
    if subset == "latin":
        from fontTools import subset as fsubset

        options = fsubset.Options()
        # fontTools' default features (kern, liga, marks, fractions, ...), as Fontsource keeps; the stylistic
        # sets a preset wants are already the default forms (make_default).
        options.name_IDs = ["*"]
        options.notdef_outline = True
        subsetter = fsubset.Subsetter(options)
        subsetter.populate(unicodes=LATIN)
        subsetter.subset(font)
    stem = f"{PS_FAMILY}{(suffix or '') if release else '-' + preset}[wght]"
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
    parser.add_argument("--release", action="store_true", help="name the family cmux Sans (or the preset's name), without the preset")
    args = parser.parse_args()
    for preset in sorted(PRESETS) if args.all else [args.preset]:
        for path in build(preset, args.subset, args.out, args.release):
            print(f"{path} {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
