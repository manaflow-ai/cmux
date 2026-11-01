#!/usr/bin/env python3
"""Bundle the animated avatar sets as Chief pet characters: Mochi, Captain, Sprout and Bolt.

Usage: python3 scripts/cmux-next/art/chief_mascot_animated.py [--check]

Each set (`cmux-avatar/1`, webviews `avatars/sets/<id>`, drawn by Codex sessions in #25213) is the
one source. Its sheet and manifest are copied into CmuxNextFloating's Resources as
`ChiefMascot<Name>Sheet.png` and `ChiefMascot<Name>.json`, which the floating pet steps. Its still,
for every surface that never animates, is the idle row's first frame drawn 7x on a 252 px square
(14 px in from each side, standing on the top edge, as Mochi's was): `ChiefMascot<Name>.png` and the
identical `…Avatar.png` in Resources, and `ChiefMascot<Name>.png` in the webviews' mascots folder.
`--check` exits 1 when a written file differs from what the sets make (zlib only).
"""
import json
import struct
import sys
import zlib

from chief_mascot_series2 import RESOURCES, ROOT, WEB, png_bytes

SETS = ROOT / "webviews/src/agent-session/acpmux/avatars/sets"
NAMES = ("mochi", "captain", "sprout", "bolt")
SCALE, SIDE, INSET = 7, 252, 14


def read_rgba(data):
    """8-bit RGBA or palette (the sets' sheets), non-interlaced: (width, pixels as RGBA bytes), with
    every transparent pixel zeroed so two encoders of one image compare equal."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, palette, alpha = 8, b"", [], b""
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and colour in (3, 6) and interlace == 0, "not 8-bit RGBA or palette"
        elif kind == b"PLTE":
            palette = [body[i:i + 3] for i in range(0, len(body), 3)]
        elif kind == b"tRNS":
            alpha = body
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    step = 4 if colour == 6 else 1
    raw, stride, out = zlib.decompress(idat), width * step, bytearray()
    prev, at = bytearray(stride), 0
    for _ in range(height):
        kind, line = raw[at], bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        for x in range(stride):
            a = line[x - step] if x >= step else 0
            b, c = prev[x], (prev[x - step] if x >= step else 0)
            if kind == 1:
                line[x] = (line[x] + a) & 255
            elif kind == 2:
                line[x] = (line[x] + b) & 255
            elif kind == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif kind == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = line
        for x in range(width):
            if colour == 6:
                pixel = line[x * 4:x * 4 + 4]
            else:
                k = line[x]
                pixel = palette[k] + bytes([alpha[k] if k < len(alpha) else 255])
            out += pixel if pixel[3] else b"\0\0\0\0"
    return width, out


def still(sheet_path, manifest):
    width, pixels = read_rgba(sheet_path.read_bytes())
    frame_w, frame_h = manifest["frame"]["width"], manifest["frame"]["height"]
    row = manifest["states"]["idle"]["row"]
    out = bytearray(SIDE * SIDE * 4)
    for y in range(min(frame_h * SCALE, SIDE)):
        sy = row * frame_h + y // SCALE
        for x in range(min(frame_w * SCALE, SIDE - INSET)):
            at = (sy * width + x // SCALE) * 4
            if pixels[at + 3]:
                to = (y * SIDE + x + INSET) * 4
                out[to:to + 4] = pixels[at:at + 4]
    return png_bytes(SIDE, SIDE, out)


def outputs():
    for name in NAMES:
        folder = SETS / name
        manifest = json.loads((folder / "avatar.json").read_text())
        resource = "ChiefMascot" + name.capitalize()
        yield RESOURCES / f"{resource}Sheet.png", (folder / "sheet.png").read_bytes()
        yield RESOURCES / f"{resource}.json", (folder / "avatar.json").read_bytes()
        data = still(folder / "sheet.png", manifest)
        for target in (RESOURCES / f"{resource}.png", RESOURCES / f"{resource}Avatar.png", WEB / f"{resource}.png"):
            yield target, data


def same(target, data):
    """A PNG matches by its pixels (Mochi's still was written by another encoder); anything else by bytes."""
    if not target.exists():
        return False
    if target.suffix != ".png":
        return target.read_bytes() == data
    return read_rgba(target.read_bytes()) == read_rgba(data)


def main():
    check = "--check" in sys.argv[1:]
    stale = []
    for target, data in outputs():
        if same(target, data):
            continue
        if check:
            stale.append(target)
        else:
            target.write_bytes(data)
            print(target.relative_to(ROOT))
    for target in stale:
        print(f"stale: {target.relative_to(ROOT)}")
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
