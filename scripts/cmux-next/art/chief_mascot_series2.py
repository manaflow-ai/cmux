#!/usr/bin/env python3
"""Generate the Chief pet's Series 2 characters: new colourways of Fox, Moon and Machine.

Usage: python3 scripts/cmux-next/art/chief_mascot_series2.py [--check]

Each Series 2 character is a recolour of a Series 1 character's bundled PNGs (the 256 px wide
`ChiefMascot<Name>.png` and its `ChiefMascot<Name>Avatar.png`), as Cyan Machine and Blue Moon are
of the originals' palette. Only saturated pixels in a recipe's hue bands change; outlines, faces,
whites and creams keep their colour, so the pixel art stays crisp. Writes both PNGs into
CmuxNextFloating's Resources and the still into the webviews' mascots folder. `--check` exits 1
when a written file differs from what the recipes make (no third-party modules: zlib only).
"""
import colorsys
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
RESOURCES = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextFloating/Resources"
WEB = ROOT / "webviews/src/agent-session/acpmux/mascots"

# A recipe: (source character, minimum saturation, bands). A band: (hue from, hue to, in degrees,
# wrapping past 360) -> (new hue, saturation factor, value factor). Pixels below the recipe's
# saturation or MIN_VAL value keep their colour (outlines, whites, creams, the dark visor).
MIN_VAL = 0.12
RECIPES = {
    # The fox's orange coat turns arctic silver-blue; its cape goes deep indigo, its gold stays.
    "FoxArctic": ("Fox", 0.18, [((330, 40), (208, 0.38, 1.10)), ((60, 260), (238, 1.00, 1.00))]),
    # The moon-moth's lavender wings turn rose and their teal turns orchid; its gold antennae stay.
    "MoonRose": ("Moon", 0.08, [((225, 300), (342, 3.0, 1.10)), ((160, 225), (318, 2.2, 1.08))]),
    # The machine's green leaves turn violet; its amber eyes and lights turn magenta-pink.
    "MachineViolet": ("Machine", 0.18, [((70, 170), (272, 1.05, 1.00)), ((350, 45), (322, 1.00, 1.05))]),
    # The machine's green leaves turn gold; its amber eyes and lights turn sky blue.
    "MachineGold": ("Machine", 0.18, [((70, 170), (42, 2.6, 1.02)), ((350, 45), (196, 1.00, 1.05))]),
}


def read_png(path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, idat, width, height = 8, b"", 0, 0
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert (depth, colour, interlace) == (8, 6, 0), f"{path}: not 8-bit RGBA, non-interlaced"
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    raw, stride, out = zlib.decompress(idat), width * 4, bytearray()
    prev, at = bytearray(stride), 0
    for _ in range(height):
        kind, line = raw[at], bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        for x in range(stride):
            a = line[x - 4] if x >= 4 else 0
            b, c = prev[x], (prev[x - 4] if x >= 4 else 0)
            if kind == 1:
                line[x] = (line[x] + a) & 255
            elif kind == 2:
                line[x] = (line[x] + b) & 255
            elif kind == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif kind == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += line
        prev = line
    return width, height, out


def png_bytes(width, height, pixels):
    stride, rows = width * 4, bytearray()
    for y in range(height):
        rows.append(0)
        rows += pixels[y * stride:(y + 1) * stride]

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"sRGB", b"\x00") + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))


def in_band(hue, band):
    start, end = band
    return start <= hue < end if start <= end else hue >= start or hue < end


def recolour(pixels, min_sat, bands):
    out = bytearray(pixels)
    cache = {}
    for i in range(0, len(out), 4):
        if out[i + 3] == 0:
            continue
        key = bytes(out[i:i + 3])
        if key not in cache:
            r, g, b = (v / 255 for v in key)
            hue, sat, val = colorsys.rgb_to_hsv(r, g, b)
            new = key
            if sat >= min_sat and val >= MIN_VAL:
                for band, (to, sat_k, val_k) in bands:
                    if in_band(hue * 360, band):
                        rgb = colorsys.hsv_to_rgb(to / 360, min(1, sat * sat_k), min(1, val * val_k))
                        new = bytes(round(v * 255) for v in rgb)
                        break
            cache[key] = new
        out[i:i + 3] = cache[key]
    return out


def outputs():
    for name, (source, min_sat, bands) in RECIPES.items():
        for suffix in ("", "Avatar"):
            width, height, pixels = read_png(RESOURCES / f"ChiefMascot{source}{suffix}.png")
            data = png_bytes(width, height, recolour(pixels, min_sat, bands))
            targets = [RESOURCES / f"ChiefMascot{name}{suffix}.png"]
            if not suffix:
                targets.append(WEB / f"ChiefMascot{name}.png")
            for target in targets:
                yield target, data


def main():
    check = "--check" in sys.argv[1:]
    stale = []
    for target, data in outputs():
        if check:
            if not target.exists() or target.read_bytes() != data:
                stale.append(target)
        else:
            target.write_bytes(data)
            print(target.relative_to(ROOT))
    for target in stale:
        print(f"stale: {target.relative_to(ROOT)}")
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
