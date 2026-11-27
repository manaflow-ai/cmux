"""The family's signature axis: one playful detail carried through every face, as its own variation axis.

The cmux family's detail is `WEFT`, named Selvedge (hq docs/research/2026-11-19-our-own-type-family.md):
threaded exit strokes, a continuous kind below (`weft`). The swap machinery serves step-wise details.
This module is the machinery any choice needs, the way Geist Serif's dot-shape axis is built: a new axis
(min, default, max), and along it steps that swap glyphs for alternates through an `rclt` feature variation.
The alternates are drawn here from the base's own outlines, at every weight master, so a variable base keeps
interpolating.

A kind is a function `(contour points at one master, glyph name, step) -> replacement contours or None`
(None keeps that contour). `KINDS` holds the written kinds; a spec naming any other kind is refused, so a
family never ships without the axis it declares.

Spec:
    "signature": {"kind": "...", "tag": "XXXX", "name": "Axis name",
                  "steps": [{"name": "Plain", "from": 0, "to": 25}, {"name": "...", "from": 25, "to": 100}, ...],
                  "glyphs": ["i", "j", "period", ...]}   optional; the kind's own default list otherwise
The first step is the base's own drawing (no swap).
"""

from __future__ import annotations

import copy
from collections.abc import Callable

from fontTools.misc.fixedTools import otRound
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.ttLib import TTFont, newTable
from fontTools.ttLib.tables import otTables
from fontTools.ttLib.tables._f_v_a_r import Axis, NamedInstance
from fontTools.ttLib.tables._g_l_y_f import Glyph, GlyphComponent, GlyphCoordinates
from fontTools.ttLib.tables.TupleVariation import TupleVariation
from fontTools.varLib.featureVars import addFeatureVariations
from fontTools.varLib.models import VariationModel, supportScalar

Point = tuple[float, float, bool]  # x, y, on-curve
Contour = list[Point]
KindFn = Callable[[Contour, str, dict], "list[Contour] | None"]

KINDS: dict[str, tuple[KindFn, list[str]]] = {}


def kind(name: str, default_glyphs: list[str]):
    def register(fn: KindFn) -> KindFn:
        KINDS[name] = (fn, default_glyphs)
        return fn

    return register


def apply_signature(font: TTFont, signature: dict, face: dict) -> None:
    name = signature.get("kind")
    if name in CONTINUOUS:
        CONTINUOUS[name](font, signature, face)
        return
    if name not in KINDS:
        raise SystemExit(f"signature kind {name!r} is not built yet (known: {sorted(KINDS) or 'none'})")
    fn, default_glyphs = KINDS[name]
    steps = signature["steps"]
    add_axis(font, signature["tag"], signature["name"], steps)
    by_char = font.getBestCmap()
    wanted = [by_char.get(ord(g), g) if len(g) == 1 else g for g in signature.get("glyphs", default_glyphs)]
    wanted = components_too(font, [g for g in wanted if g in font["glyf"]])
    rules = []
    for index, step in enumerate(steps[1:], start=1):
        mapping = {}
        for glyph_name in wanted:
            alt = alternate(font, glyph_name, f"{glyph_name}.sig{index}", lambda c, g=glyph_name, s=step: fn(c, g, s))
            if alt:
                mapping[glyph_name] = alt
        mapping.update(composite_alternates(font, mapping, index))
        if mapping:
            rules.append(([{signature["tag"]: (normalized(step["from"], steps), normalized(step["to"], steps))}], mapping))
    if rules:
        # rclt, not rvrn: a base may carry its own rvrn variation (Literata swaps glyphs at heavy weights),
        # and every renderer applies rclt without being asked, as it does rvrn.
        addFeatureVariations(font, rules, featureTag="rclt")


def components_too(font: TTFont, names: list[str]) -> list[str]:
    """The glyphs and, for composites (an i built from a dotless i and a dot), every glyph they are built
    from, so a kind sees the dot itself; the composites then follow through `composite_alternates`."""
    glyf, out, todo = font["glyf"], [], list(names)
    while todo:
        name = todo.pop(0)
        if name in out:
            continue
        out.append(name)
        if glyf[name].isComposite():
            todo.extend(component.glyphName for component in glyf[name].components)
    return out


def swaps(font: TTFont) -> list[tuple[dict, dict[str, str]]]:
    """The signature's glyph swaps as built: (axis box, {glyph: alternate}) per step, read back from GSUB."""
    gsub = font["GSUB"].table
    out = []
    for record in gsub.FeatureVariations.FeatureVariationRecord if gsub.FeatureVariations else []:
        box = {}
        fvar_axes = font["fvar"].axes
        for condition in record.ConditionSet.ConditionTable:
            box[fvar_axes[condition.AxisIndex].axisTag] = (condition.FilterRangeMinValue, condition.FilterRangeMaxValue)
        mapping: dict[str, str] = {}
        for substitution in record.FeatureTableSubstitution.SubstitutionRecord:
            for index in substitution.Feature.LookupListIndex:
                for table in gsub.LookupList.Lookup[index].SubTable:
                    mapping.update(getattr(table, "mapping", {}))
        out.append((box, mapping))
    return out


def axis_range(steps: list[dict]) -> tuple[float, float, float]:
    return steps[0]["from"], steps[0]["from"], steps[-1]["to"]


def normalized(value: float, steps: list[dict]) -> float:
    lo, default, hi = axis_range(steps)
    return 0.0 if hi == default else (value - default) / (hi - default)


def add_axis(font: TTFont, tag: str, name: str, steps: list[dict]) -> None:
    """Adds the axis to fvar (making one for a static base) with a named instance per step, and to STAT."""
    lo, default, hi = axis_range(steps)
    # Tables that decode against fvar's axis count must be read before the axis lands (fontTools loads lazily).
    for lazy in ("gvar", "cvar", "HVAR", "VVAR", "MVAR", "GDEF", "STAT", "avar"):
        if lazy in font:
            font[lazy].ensureDecompiled() if hasattr(font[lazy], "ensureDecompiled") else None
    names = font["name"]
    if "fvar" not in font:
        font["fvar"] = newTable("fvar")
        font["fvar"].axes, font["fvar"].instances = [], []
    fvar = font["fvar"]
    if any(axis.axisTag == tag for axis in fvar.axes):
        raise SystemExit(f"the base already has a {tag} axis")
    axis = Axis()
    axis.axisTag, axis.minValue, axis.defaultValue, axis.maxValue = tag, lo, default, hi
    axis.axisNameID = names.addMultilingualName({"en": name}, font, minNameID=256)
    fvar.axes.append(axis)
    defaults = {a.axisTag: a.defaultValue for a in fvar.axes}
    existing = fvar.instances or []
    for instance in existing:
        instance.coordinates[tag] = default
    for step in steps[1:]:
        instance = NamedInstance()
        instance.coordinates = {**defaults, tag: step["from"]}
        instance.subfamilyNameID = names.addMultilingualName({"en": step["name"]}, font, minNameID=256)
        fvar.instances.append(instance)
    # gvar deltas do not name the new axis, so they apply at every value of it, as they should. Item variation
    # stores (HVAR, VVAR, MVAR, GDEF) list one entry per axis in every region: the new axis gets a neutral one.
    for tag_name in ("HVAR", "VVAR", "MVAR", "GDEF"):
        store = getattr(font[tag_name].table, "VarStore", None) if tag_name in font else None
        if store is None:
            continue
        regions = store.VarRegionList
        for region in regions.Region:
            neutral = otTables.VarRegionAxis()
            neutral.StartCoord, neutral.PeakCoord, neutral.EndCoord = 0.0, 0.0, 0.0
            region.VarRegionAxis.append(neutral)
        regions.RegionAxisCount = len(fvar.axes)
    if "avar" in font:
        font["avar"].segments[tag] = {-1.0: -1.0, 0.0: 0.0, 1.0: 1.0}
    if "STAT" in font:
        stat = font["STAT"].table
        record = otTables.AxisRecord()
        record.AxisTag, record.AxisNameID, record.AxisOrdering = tag, axis.axisNameID, len(stat.DesignAxisRecord.Axis)
        stat.DesignAxisRecord.Axis.append(record)
        stat.DesignAxisCount = len(stat.DesignAxisRecord.Axis)


def master_locations(font: TTFont, glyph_name: str) -> tuple[list[dict], list[TupleVariation]]:
    variations = font["gvar"].variations.get(glyph_name, []) if "gvar" in font else []
    variations = [copy.deepcopy(v) for v in variations]  # inferring deltas below must not touch the base glyph
    peaks: list[dict] = []
    for variation in variations:
        peak = {tag: values[1] for tag, values in variation.axes.items()}
        if peak not in peaks:
            peaks.append(peak)
    return [{}] + peaks, variations


def contours_at(font: TTFont, glyph_name: str, location: dict, variations: list[TupleVariation]) -> list[Contour]:
    glyf = font["glyf"]
    coords, controls = glyf._getCoordinatesAndControls(glyph_name, font["hmtx"].metrics, None)
    end_pts, flags = controls[1], controls[2]
    points = GlyphCoordinates(coords)
    for variation in variations:
        if None in variation.coordinates:
            variation.calcInferredDeltas(coords, end_pts)
        scalar = supportScalar(location, variation.axes)
        if scalar:
            points += GlyphCoordinates(variation.coordinates) * scalar
    out, start = [], 0
    for end in end_pts:
        out.append([(points[i][0], points[i][1], bool(flags[i] & 1)) for i in range(start, end + 1)])
        start = end + 1
    return out


def alternate(font: TTFont, glyph_name: str, new_name: str, fn: Callable[[Contour], "list[Contour] | None"]) -> str | None:
    """A copy of a simple glyph with `fn` applied to each contour at every master; None when nothing changed.
    The new glyph's deltas are solved from the masters (the cmux Sans method), so it interpolates."""
    glyf = font["glyf"]
    glyph = glyf[glyph_name]
    if glyph.isComposite() or glyph.numberOfContours <= 0:
        return None
    locations, variations = master_locations(font, glyph_name)
    masters = []
    changed = False
    for location in locations:
        contours = []
        for contour in contours_at(font, glyph_name, location, variations):
            replaced = fn(contour)
            if replaced is None:
                contours.append(contour)
            else:
                changed = True
                contours.extend(replaced)
        masters.append(contours)
    if not changed:
        return None
    shapes = [[len(c) for c in m] for m in masters]
    if any(shape != shapes[0] for shape in shapes):
        raise SystemExit(f"{glyph_name}: the signature drew a different point structure at another master")
    new = Glyph()
    default = masters[0]
    new.coordinates = GlyphCoordinates([(otRound(x), otRound(y)) for c in default for x, y, _ in c])
    new.flags = bytearray(1 if on else 0 for c in default for *_, on in c)
    ends, total = [], 0
    for c in default:
        total += len(c)
        ends.append(total - 1)
    new.endPtsOfContours = ends
    new.numberOfContours = len(default)
    new.program = copy.deepcopy(getattr(glyph, "program", None)) if hasattr(glyph, "program") else None
    if new.program is None:
        from fontTools.ttLib.tables import ttProgram

        new.program = ttProgram.Program()
        new.program.fromBytecode(b"")
    add_glyph(font, new_name, new, glyph_name)
    if "gvar" in font and len(locations) > 1:
        axis_order = [axis.axisTag for axis in font["fvar"].axes]
        model = VariationModel(locations, axisOrder=axis_order)
        flat = [GlyphCoordinates([(x, y) for c in m for x, y, _ in c] + [(0, 0)] * 4) for m in masters]
        # Phantom points: the advance follows the base glyph's own deltas.
        base_coords, _ = glyf._getCoordinatesAndControls(glyph_name, font["hmtx"].metrics, None)
        for i, location in enumerate(locations):
            phantom = GlyphCoordinates(base_coords[-4:])
            for variation in variations:
                scalar = supportScalar(location, variation.axes)
                if scalar:
                    phantom += GlyphCoordinates(variation.coordinates[-4:]) * scalar
            for k in range(4):
                flat[i][len(flat[i]) - 4 + k] = phantom[k]
        deltas = model.getDeltas(flat)
        font["gvar"].variations[new_name] = [
            TupleVariation(support, [(otRound(x), otRound(y)) for x, y in delta])
            for support, delta in zip(model.supports[1:], deltas[1:])
        ]
    return new_name


def composite_alternates(font: TTFont, mapping: dict[str, str], index: int) -> dict[str, str]:
    """Composites built from a swapped glyph (an accented i over a dotless i and a dot) get alternates that
    point at the swapped components, since a glyph swap does not reach inside a composite."""
    glyf = font["glyf"]
    out = {}
    for name in list(glyf.keys()):
        glyph = glyf[name]
        if not glyph.isComposite() or not any(c.glyphName in mapping for c in glyph.components):
            continue
        new = Glyph()
        new.numberOfContours = -1
        new.components = []
        for component in glyph.components:
            twin = GlyphComponent()
            twin.__dict__.update(copy.deepcopy(component.__dict__))
            twin.glyphName = mapping.get(component.glyphName, component.glyphName)
            new.components.append(twin)
        new_name = f"{name}.sig{index}"
        add_glyph(font, new_name, new, name)
        if "gvar" in font and name in font["gvar"].variations:
            font["gvar"].variations[new_name] = copy.deepcopy(font["gvar"].variations[name])
        out[name] = new_name
    return out


def add_glyph(font: TTFont, name: str, glyph: Glyph, like: str) -> None:
    """Adds `name`, with the advance, side bearing and advance variations of `like`, the glyph it replaces."""
    metrics = font["hmtx"][like]
    order = list(font.getGlyphOrder())
    if name in order:
        raise SystemExit(f"{name} already exists")
    glyf = font["glyf"]
    # glyf keeps its own glyph order (often the font's list itself): set one order, then the glyph.
    font.setGlyphOrder(order + [name])
    glyf.glyphOrder = font.getGlyphOrder()
    glyf.glyphs[name] = glyph
    font["hmtx"][name] = metrics
    if "vmtx" in font:
        font["vmtx"][name] = font["vmtx"][like]
    for tag in ("HVAR", "VVAR"):
        if tag not in font:
            continue
        table = font[tag].table
        for attr in ("AdvWidthMap", "AdvHeightMap", "LsbMap", "RsbMap", "TsbMap", "BsbMap", "VOrgMap"):
            index_map = getattr(table, attr, None)
            if index_map is not None and like in index_map.mapping:
                index_map.mapping[name] = index_map.mapping[like]
    glyph.recalcBounds(font["glyf"])
    font["maxp"].numGlyphs = len(font.getGlyphOrder())


def bounds(contour: Contour) -> tuple[float, float, float, float]:
    xs, ys = [p[0] for p in contour], [p[1] for p in contour]
    return min(xs), min(ys), max(xs), max(ys)


def is_dot(contour: Contour, upem: int = 1000) -> bool:
    """A small, near-square closed shape: a tittle, a period, the dots of a colon or an umlaut."""
    x0, y0, x1, y1 = bounds(contour)
    w, h = x1 - x0, y1 - y0
    return 0 < w < upem * 0.22 and 0 < h < upem * 0.22 and 0.6 < w / h < 1.6


__all__ = ["KINDS", "apply_signature", "kind", "is_dot", "bounds", "DecomposingRecordingPen"]


# Continuous kinds: the axis moves outlines through gvar deltas, so every value between its ends draws (no
# glyph swap). A kind is `(font, signature, face) -> None` and adds the axis itself.
CONTINUOUS: dict[str, Callable[[TTFont, dict, dict], None]] = {}

OVERLAP_SIMPLE = 0x40
WEFT_LETTERS = "nmhaudilt"


def weft(font: TTFont, signature: dict, face: dict) -> None:
    """`WEFT` (hq docs/research/2026-11-19-our-own-type-family.md): from a clean cut at 0 to a short threaded
    exit stroke at 100, leaving the foot of a letter's last stem and leaning toward the next letter, like weft
    passing between warp. Each letter gets one more contour, drawn with no area at 0 (all four points on the
    stem's foot) and opened by a delta at the axis's top, so the default draws exactly as before. No advance,
    side bearing or vertical metric changes: text never reflows when the axis moves."""
    tag = signature.get("tag", "WEFT")
    top = signature.get("max", 100)
    add_axis(font, tag, signature.get("name", "Weft"),
             [{"name": "Cut", "from": 0, "to": 0}, {"name": "Weft", "from": top, "to": top}])
    glyf, hmtx = font["glyf"], font["hmtx"]
    cmap = font.getBestCmap()
    x_height = font["OS/2"].sxHeight or 530
    letters = signature.get("glyphs", WEFT_LETTERS)
    # A composite letter (an i of a dotless i and a dot) threads its base, the first component; marks have no foot.
    names = []
    for c in letters:
        if ord(c) not in cmap:
            continue
        name = cmap[ord(c)]
        while glyf[name].isComposite():
            name = glyf[name].components[0].glyphName
        if name not in names:
            names.append(name)
    for name in names:
        glyph = glyf[name]
        if glyph.isComposite() or glyph.numberOfContours <= 0:
            continue
        foot = stem_foot(glyph)
        if foot is None:
            raise SystemExit(f"Selvedge: {name} has no stem foot on the baseline to thread from")
        right, stem = foot
        advance = hmtx[name][0]
        thread = max(24, otRound(stem * 0.5))
        start = (right - thread, 0)
        end_x = advance + 30  # past the advance, under the next letter's first stroke
        end_y = otRound(x_height * 0.2)
        # Clockwise in y-up (the outer direction): up the stem, along the top of the thread, down its tip, back.
        full = [start, (start[0], thread), (end_x, end_y + otRound(thread * 0.6)), (end_x, end_y)]
        add_collapsed_contour(font, name, start, full, tag)


def stem_foot(glyph) -> tuple[int, int] | None:
    """The bottom right corner of the glyph's last stem on the baseline, and the stem's width."""
    # Points near the baseline (a curved or bracketed serif foot sits a few units off it), on or off curve.
    glyph_bottom = min(y for _, y in glyph.coordinates)
    band = max(12, -glyph_bottom + 4) if glyph_bottom > -40 else 12
    on_base = sorted(x for (x, y) in glyph.coordinates if -band <= y <= band)
    if len(on_base) < 2:
        return None
    right = on_base[-1]
    left = next((x for x in reversed(on_base[:-1]) if 20 <= right - x <= 220), None)
    return right, (right - left) if left is not None else 80


def add_collapsed_contour(font: TTFont, name: str, at: tuple[int, int], full: list[tuple[int, int]], tag: str) -> None:
    glyf = font["glyf"]
    glyph = glyf[name]
    n_old = len(glyph.coordinates)
    glyph.coordinates.extend(GlyphCoordinates([at] * len(full)))
    glyph.flags.extend(bytearray([1] * len(full)))
    glyph.endPtsOfContours.append(n_old + len(full) - 1)
    glyph.numberOfContours += 1
    glyph.flags[0] |= OVERLAP_SIMPLE  # the thread overlaps the stem; macOS fills overlaps only with this bit
    if hasattr(glyph, "program"):
        from fontTools.ttLib.tables import ttProgram

        glyph.program = ttProgram.Program()  # instructions name point numbers; the new points would shift them
        glyph.program.fromBytecode(b"")
    if "gvar" not in font:
        # A static base (an axis pinned away) gets its first glyph variations here.
        gvar = font["gvar"] = newTable("gvar")
        gvar.version, gvar.reserved, gvar.variations = 1, 0, {}
    if "gvar" in font:
        variations = font["gvar"].variations.setdefault(name, [])
        for variation in variations:
            # The phantom points stay last; the new contour has no movement along the other axes.
            variation.coordinates[n_old:n_old] = [(0, 0)] * len(full)
        deltas = [None] * n_old + [(x - at[0], y - at[1]) for x, y in full] + [None] * 4
        variations.append(TupleVariation({tag: (0.0, 1.0, 1.0)}, deltas))
    glyph.recalcBounds(glyf)


CONTINUOUS["weft"] = weft
