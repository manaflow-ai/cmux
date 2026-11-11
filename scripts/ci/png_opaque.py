#!/usr/bin/env python3
"""Rewrite fully opaque RGBA PNGs as RGB PNGs, in place: App Store screenshots.

    png_opaque.py FILE.png [FILE.png ...]

App Store Connect refuses a screenshot that has an alpha channel, and
`simctl io screenshot` writes 8-bit RGBA even when every pixel is opaque (its
`--mask=black` drops the channel but paints the display's corners black). This
drops the channel without changing a pixel. A file that is already RGB is left
as it is; one with any pixel not fully opaque, or one that is not a plain 8-bit
non-interlaced PNG, is refused (exit 1) and left unchanged, since dropping its
alpha would change what it shows. Standard library only: the fleet's Macs have
no image tools beyond sips, which cannot drop the channel.
"""
from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path

SIGNATURE = b"\x89PNG\r\n\x1a\n"


def chunks(data: bytes):
    if not data.startswith(SIGNATURE):
        raise ValueError("not a PNG")
    pos = len(SIGNATURE)
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        yield kind, data[pos + 8:pos + 8 + length]
        pos += 12 + length


def chunk(kind: bytes, body: bytes) -> bytes:
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)


def unfilter(raw: bytes, width: int, height: int, bpp: int) -> bytearray:
    stride = width * bpp
    out = bytearray(stride * height)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        kind = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if kind == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif kind == 2:
            line = bytearray((a + b) & 0xFF for a, b in zip(line, prev))
        elif kind == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif kind == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        elif kind != 0:
            raise ValueError(f"unknown filter type {kind} on row {y}")
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return out


def opaque_rgb(data: bytes) -> bytes | None:
    """The RGB PNG for an opaque 8-bit RGBA PNG, None when it is RGB already; ValueError otherwise."""
    header = None
    idat = bytearray()
    for kind, body in chunks(data):
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
    if header is None:
        raise ValueError("no IHDR")
    width, height, depth, color, _, _, interlace = header
    if depth == 8 and color == 2:
        return None
    if depth != 8 or color != 6 or interlace != 0:
        raise ValueError(f"wants 8-bit RGBA, not interlaced (depth {depth}, color type {color}, interlace {interlace})")
    pixels = unfilter(zlib.decompress(bytes(idat)), width, height, 4)
    alpha = pixels[3::4]
    if alpha.count(255) != len(alpha):
        raise ValueError("has pixels that are not fully opaque")
    rgb = bytearray(width * height * 3)
    rgb[0::3], rgb[1::3], rgb[2::3] = pixels[0::4], pixels[1::4], pixels[2::4]
    stride = width * 3
    rows = b"".join(b"\x00" + bytes(rgb[y * stride:(y + 1) * stride]) for y in range(height))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def main(paths: list[str]) -> int:
    if not paths:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    failed = 0
    for name in paths:
        path = Path(name)
        try:
            rgb = opaque_rgb(path.read_bytes())
        except (OSError, ValueError, zlib.error) as error:
            print(f"png_opaque.py: {name}: {error}", file=sys.stderr)
            failed = 1
            continue
        if rgb is not None:
            tmp = path.with_name(path.name + ".tmp")
            tmp.write_bytes(rgb)
            tmp.replace(path)
    return failed


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
