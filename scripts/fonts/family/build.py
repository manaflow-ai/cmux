#!/usr/bin/env python3
"""Builds a cmux type family (Sans, Serif text, Serif display, Mono) from OFL bases, on one line box.

Leo, 2026-11-19: "i mean like we can get inspired building our own" and "quillet is our anthropic inspired one.
we do want our own separate one!". The family's idea comes from how Geist Serif was made, not from its look:
every face shares one set of vertical metrics, so swapping a reply from the sans to the serif, or a code span
into prose, never moves a line; and one signature axis carries a playful detail through all of them.

The bases are a family spec's choice (a JSON file, see `spec.example.json` and `tests/fixture.json`); this
script knows no font by name. For each face of the spec it:

1. loads the base: a repo path, or a URL whose bytes match a sha256 (cached in ~/.cache/cmux-fonts), with an
   optional zip member;
2. pins or narrows its variation axes (`axes`: a number pins, `[min, max]` narrows, `[min, default, max]`
   also moves the default instance, the one a renderer draws when no weight is asked for), so a serif with
   an optical-size axis gives a text face and a display face;
3. brings it to 1000 units per em, scaled by `scale` (an optical-size factor: every outline and metric grows,
   the em stays), or by `match_x_height`, which picks the scale that lands the face's x-height on the
   family's;
4. cuts it to Fontsource's Latin range (plus `extra_codepoints`), keeping fontTools' default features;
5. applies the family's signature axis, if the spec names one (`signature.py`);
6. sets the family's line box on it: hhea and OS/2 typo (with USE_TYPO_METRICS), equal across faces, line
   gap 0, and the same at every axis location; OS/2 win ascent and descent cover the box and the face's ink
   (Windows clips there, and with USE_TYPO_METRICS no renderer takes them for the line box);
7. renames it (the OFL reserves names a base declares; `reserved` lists them and the build fails if one
   survives) and puts our modification notice after the base's copyright;
8. writes `<File>.woff2` (and `.ttf` with --ttf), then `manifest.json` (bytes, sha256, metrics) and
   `OFL-<Family>.txt`, every base's copyright line with the OFL text.

The family has at most `max_faces` faces (8 by default, the chat pack's limit), and every face must end on
the same line box: `check.py` asserts both on the written files, so CI catches a face that would shift.

Needs fontTools and brotli. Usage:
    build.py SPEC.json --out DIR [--ttf]
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path

from fontTools.misc.fixedTools import otRound
from fontTools.ttLib import TTFont
from fontTools.ttLib.scaleUpem import scale_upem

REPO = Path(__file__).resolve().parents[3]
CACHE = Path.home() / ".cache" / "cmux-fonts"

# Fontsource's "latin" subset, the range every bundled chat face is cut to (chatFonts/FONTS.md).
LATIN = [
    *range(0x00, 0x100), 0x131, 0x152, 0x153, 0x2BB, 0x2BC, 0x2C6, 0x2DA, 0x2DC, 0x304, 0x308, 0x329,
    *range(0x2000, 0x2070), 0x20AC, 0x2122, 0x2191, 0x2193, 0x2212, 0x2215, 0xFEFF, 0xFFFD,
]

ROLES = ("sans", "serif-text", "serif-display", "mono")
USE_TYPO_METRICS = 1 << 7


@dataclass(frozen=True)
class LineBox:
    """The family's vertical metrics in units of a 1000 em. A line set at line-height N draws N em tall in
    every face, and its baseline sits at the same height, because each face reports these same numbers."""

    ascender: int
    descender: int  # negative

    @property
    def height(self) -> int:
        return self.ascender - self.descender


def load_source(source: dict) -> TTFont:
    if "path" in source:
        data = (REPO / source["path"]).read_bytes()
    else:
        url = source["url"]
        cache = CACHE / hashlib.sha256(url.encode()).hexdigest()[:16] / url.rsplit("/", 1)[1]
        if not cache.exists():
            cache.parent.mkdir(parents=True, exist_ok=True)
            with urllib.request.urlopen(url) as response:
                cache.write_bytes(response.read())
        data = cache.read_bytes()
    want = source.get("sha256")
    if want and hashlib.sha256(data).hexdigest() != want:
        raise SystemExit(f"{source}: sha256 does not match {want}")
    if "member" in source:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            data = archive.read(source["member"])
    font = TTFont(io.BytesIO(data), recalcTimestamp=False)  # reproducible files
    font.flavor = None
    return font


def reload(font: TTFont) -> TTFont:
    """A fresh copy of the font from its own bytes. fontTools' instancer and scale_upem leave lazily loaded
    tables (gvar) without entries for some glyphs, which the subsetter then trips on; a save and load
    settles every table."""
    buffer = io.BytesIO()
    font.save(buffer)
    buffer.seek(0)
    return TTFont(buffer, recalcTimestamp=False)


def limit_axes(font: TTFont, axes: dict) -> TTFont:
    if not axes or "fvar" not in font:
        return font
    from fontTools.varLib import instancer

    limits = {tag: (tuple(value) if isinstance(value, list) else value) for tag, value in axes.items()}
    return instancer.instantiateVariableFont(font, limits, updateFontNames=False)


def x_height(font: TTFont) -> float:
    os2 = font["OS/2"]
    if getattr(os2, "sxHeight", 0):
        return os2.sxHeight
    glyf, cmap = font["glyf"], font.getBestCmap()
    glyph = glyf[cmap[ord("x")]]
    glyph.recalcBounds(glyf)
    return glyph.yMax


def to_em(font: TTFont, scale: float) -> None:
    """Every outline and metric times `scale`, on a 1000 em (the cmux Sans optical-size method)."""
    upem = font["head"].unitsPerEm
    target = otRound(1000 * scale)
    if upem != target:
        scale_upem(font, target)
    font["head"].unitsPerEm = 1000


def subset(font: TTFont, extra: list[int]) -> None:
    from fontTools import subset as fsubset

    options = fsubset.Options()
    options.name_IDs = ["*"]
    options.notdef_outline = True  # fontTools' default features, as Fontsource keeps
    subsetter = fsubset.Subsetter(options)
    subsetter.populate(unicodes=[*LATIN, *extra])
    subsetter.subset(font)


def set_line_box(font: TTFont, box: LineBox) -> None:
    hhea, os2 = font["hhea"], font["OS/2"]
    hhea.ascent, hhea.descent, hhea.lineGap = box.ascender, box.descender, 0
    os2.sTypoAscender, os2.sTypoDescender, os2.sTypoLineGap = box.ascender, box.descender, 0
    # Windows clips outside win ascent/descent; they cover the box and every glyph's ink.
    low, high = ink_bounds(font)
    os2.usWinAscent, os2.usWinDescent = max(box.ascender, high), max(-box.descender, -low)
    if os2.version < 4:
        os2.version = 4
    os2.fsSelection |= USE_TYPO_METRICS
    if "MVAR" in font:
        # Variable metrics would move the box along an axis; the box is the family's at every location.
        mvar = font["MVAR"].table
        moving = {"hasc", "hdsc", "hlgp", "tasc", "tdsc", "tlgp", "hcla", "hcld"}
        keep = [r for r in mvar.ValueRecord if r.ValueTag not in moving]
        mvar.ValueRecord = keep
        mvar.ValueRecordCount = len(keep)
        if not keep:
            del font["MVAR"]


def ink_bounds(font: TTFont) -> tuple[int, int]:
    """Lowest and highest ink of the cut font at its default location, from the glyphs themselves (head's
    bounds are stale until the font is saved)."""
    glyf = font["glyf"]
    lows, highs = [0], [0]
    for name in font.getGlyphOrder():
        glyph = glyf[name]
        glyph.recalcBounds(glyf)
        if glyph.numberOfContours:
            lows.append(glyph.yMin)
            highs.append(glyph.yMax)
    return min(lows), max(highs)


def referenced_name_ids(font: TTFont) -> set[int]:
    used: set[int] = set()
    if "fvar" in font:
        for axis in font["fvar"].axes:
            used.add(axis.axisNameID)
        for instance in font["fvar"].instances:
            used.add(instance.subfamilyNameID)
            if instance.postscriptNameID != 0xFFFF:
                used.add(instance.postscriptNameID)
    if "STAT" in font:
        stat = font["STAT"].table
        used.add(stat.ElidedFallbackNameID)
        for record in stat.DesignAxisRecord.Axis if stat.DesignAxisRecord else []:
            used.add(record.AxisNameID)
        for value in stat.AxisValueArray.AxisValue if stat.AxisValueArray else []:
            used.add(value.ValueNameID)
    return used


def rename(font: TTFont, family: str, face: dict, notice: str, reserved: list[str]) -> str:
    """Names the face `<family> <face name>`, typographic family `family`, subfamily from the face. Returns the
    PostScript name. Keeps the base's copyright line (OFL 1.20) and adds ours."""
    style = face.get("style", "Regular")
    full_family = f"{family} {face['name']}"
    ps = (full_family.replace(" ", "") + "-" + style.replace(" ", "")).replace("--", "-")
    names = font["name"]
    base_copyright = names.getDebugName(0) or ""
    # Every name that identifies the base goes: family and style names, the base's trademark, vendor,
    # designer, URLs, description, sample text. The license (13, 14) and axis/instance names (256+) stay.
    for name_id in sorted({record.nameID for record in names.names}):
        if name_id < 256 and name_id not in (13, 14):
            names.removeNames(nameID=name_id)
    copyright = " ".join(part for part in (base_copyright.strip(), notice) if part)
    for name_id, text in (
        (0, copyright),
        (1, full_family),
        (2, "Regular"),
        (3, f"{face.get('version', '0.100')};CMUX;{ps}"),
        (4, f"{full_family} {style}".strip()),
        (5, f"Version {face.get('version', '0.100')}"),
        (6, ps),
        (16, full_family),
        (17, style),
        (25, ps.split("-")[0]),
    ):
        names.setName(text, name_id, 3, 1, 0x409)
        names.setName(text, name_id, 1, 0, 0)
    if "fvar" in font:
        for instance in font["fvar"].instances:
            instance.postscriptNameID = 0xFFFF
    if "STAT" in font:
        font["STAT"].table.ElidedFallbackNameID = 2
    # Names past 255 that nothing points at any more (the instances' PostScript names, the base's own
    # strings) go; the ones axes, instances and STAT still name stay and are checked below.
    used = referenced_name_ids(font)
    for name_id in sorted({record.nameID for record in names.names}):
        if name_id > 255 and name_id not in used:
            names.removeNames(nameID=name_id)
    for record in names.names:
        text = record.toUnicode()
        if record.nameID in (0, 13, 14):
            continue
        for word in reserved:
            if word.lower() in text.lower():
                raise SystemExit(f"{ps}: name {record.nameID} keeps the Reserved Font Name {word!r}: {text!r}")
    font["OS/2"].achVendID = "CMUX"
    for table in ("DSIG", "meta"):
        if table in font:
            del font[table]
    return ps


def build_face(spec: dict, face: dict, box: LineBox | None, family_x: float | None) -> tuple[TTFont, dict]:
    import vertical  # this directory

    font = reload(limit_axes(load_source(face["source"]), face.get("axes", {})))
    subset(font, face.get("extra_codepoints", []))
    scale = face.get("scale", 1.0)
    cap = face.get("cap")  # "uniform" or "vertical": reach the family's cap height (spec "cap_height")
    if face.get("match_x_height") and family_x:
        native = x_height(font) * 1000 / font["head"].unitsPerEm
        scale = family_x / native
    elif cap == "uniform":
        scale = spec["cap_height"] / (vertical.match_cap(font) * 1000 / font["head"].unitsPerEm)
    to_em(font, scale)
    font = reload(font)
    if cap == "vertical":
        scale = spec["cap_height"] / vertical.match_cap(font)
        vertical.scale_vertical(font, scale)
    if face.get("lowercase"):
        vertical.set_lowercase(font, spec["x_height"], spec["ascender"], spec["descender"])
    vertical.track(font, face.get("tracking", 0))
    font = reload(font)
    if spec.get("signature"):
        from signature import apply_signature  # this directory; a separate step so bases stay swappable

        apply_signature(font, spec["signature"], face)
    if box is not None:
        set_line_box(font, box)
    ps = rename(font, spec["family"], face, spec["notice"], face.get("reserved", []))
    return font, {"ps": ps, "scale": round(scale, 4), "x_height": otRound(x_height(font))}


def family_line_box(spec: dict, fonts: list[TTFont]) -> LineBox:
    """The spec's line box, or the smallest box holding every face's ink (cut to Latin, so accents on
    capitals fit and nothing past them stretches it)."""
    if "line_box" in spec:
        return LineBox(spec["line_box"]["ascender"], spec["line_box"]["descender"])
    lows, highs = zip(*(ink_bounds(font) for font in fonts))
    return LineBox(max(highs), min(lows))


def build(spec_path: Path, out: Path, ttf: bool) -> dict:
    spec = json.loads(spec_path.read_text())
    faces = spec["faces"]
    max_faces = spec.get("max_faces", 8)
    if len(faces) > max_faces:
        raise SystemExit(f"{spec['family']}: {len(faces)} faces, the limit is {max_faces}")
    for face in faces:
        if face["role"] not in ROLES:
            raise SystemExit(f"{face['name']}: role {face['role']!r} is not one of {ROLES}")
    family_x = spec.get("x_height")
    # Two passes: the first measures each face's ink after its scale and cut, the second sets the box the
    # family agrees on (unless the spec fixes one).
    box = None if "line_box" not in spec else family_line_box(spec, [])
    if box is None:
        box = family_line_box(spec, [build_face(spec, face, None, family_x)[0] for face in faces])
    out.mkdir(parents=True, exist_ok=True)
    manifest = {"family": spec["family"], "line_box": [box.ascender, box.descender], "faces": []}
    for face in faces:
        font, info = build_face(spec, face, box, family_x)
        stem = info["ps"]
        written = []
        if ttf:
            font.flavor = None
            font.save(out / f"{stem}.ttf")
            written.append(f"{stem}.ttf")
        font.flavor = "woff2"
        path = out / f"{stem}.woff2"
        font.save(path)
        data = path.read_bytes()
        manifest["faces"].append(
            {
                "name": face["name"],
                "role": face["role"],
                "file": path.name,
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "base": face["base"],
                "axes": [
                    [a.axisTag, a.minValue, a.defaultValue, a.maxValue] for a in font["fvar"].axes
                ]
                if "fvar" in font
                else [],
                **info,
            }
        )
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    write_notice(spec, out)
    return manifest


def write_notice(spec: dict, out: Path) -> Path:
    """OFL 1.20: the bases' copyright statements, the license notice and the license text."""
    lines = []
    seen = set()
    for face in spec["faces"]:
        line = face.get("copyright")
        if line and line not in seen:
            seen.add(line)
            lines.append(line)
    lines.append(spec["notice"])
    bases = sorted({face["base"] for face in spec["faces"]})
    faces_named = ", ".join(f"{spec['family']} {face['name']}" for face in spec["faces"])
    reserved = sorted({word for face in spec["faces"] for word in face.get("reserved", [])})
    lines += [
        "",
        f"The {spec['family']} fonts ({faces_named}) are Modified Versions of {', '.join(bases)}, renamed, with Manaflow's"
        " modifications."
        + (f" They do not use the Reserved Font Name{'s' if len(reserved) > 1 else ''} {', '.join(repr(w) for w in reserved)}." if reserved else ""),
        "",
        "This Font Software is licensed under the SIL Open Font License, Version 1.1.",
        "This license is copied below, and is also available with a FAQ at:",
        "https://openfontlicense.org",
        "",
        (Path(__file__).with_name("OFL-1.1.txt")).read_text().rstrip(),
        "",
    ]
    path = out / f"OFL-{spec['family'].replace(' ', '')}.txt"
    path.write_text("\n".join(lines))
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("spec", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--ttf", action="store_true", help="also write .ttf files")
    args = parser.parse_args()
    manifest = build(args.spec, args.out, args.ttf)
    for face in manifest["faces"]:
        print(f"{face['file']} {face['bytes']} bytes")
    print(f"line box {manifest['line_box']}")


if __name__ == "__main__":
    main()
