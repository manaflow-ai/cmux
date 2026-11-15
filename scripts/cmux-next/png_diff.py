"""Pixel difference between two PNGs, no third-party modules (hot-verify.py waits for a change to show).

Decodes 8-bit RGB/RGBA, non-interlaced PNGs (what screencapture and CuaDriver write) with zlib and the five PNG
row filters. `changed(a, b)` is the fraction of pixels whose color differs by more than TOLERANCE on any channel;
images of different sizes count as fully changed.
"""
from __future__ import annotations

import struct
import zlib
from pathlib import Path

TOLERANCE = 8
SIGNATURE = b"\x89PNG\r\n\x1a\n"


def decode(path: Path) -> tuple[int, int, int, bytes]:
    """(width, height, bytes per pixel, unfiltered pixel rows joined)."""
    data = Path(path).read_bytes()
    if not data.startswith(SIGNATURE):
        raise ValueError(f"{path}: not a PNG")
    pos, idat, header = len(SIGNATURE), [], None
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
    if header is None:
        raise ValueError(f"{path}: no IHDR")
    width, height, depth, color, _, _, interlace = header
    channels = {2: 3, 6: 4, 0: 1, 4: 2}.get(color)
    if depth != 8 or channels is None or interlace:
        raise ValueError(f"{path}: unsupported PNG (depth {depth}, color {color}, interlace {interlace})")
    raw = zlib.decompress(b"".join(idat))
    bpp, stride = channels, width * channels
    out = bytearray(height * stride)
    prev = bytearray(stride)
    src = 0
    for y in range(height):
        kind = raw[src]
        line = bytearray(raw[src + 1:src + 1 + stride])
        src += 1 + stride
        if kind == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif kind == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif kind == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif kind == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b, c = prev[i], prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        elif kind != 0:
            raise ValueError(f"{path}: bad filter {kind} on row {y}")
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return width, height, bpp, bytes(out)


def changed(a: Path, b: Path, step: int = 4) -> float:
    """The fraction of sampled pixels (every STEP-th pixel of every STEP-th row) that differ between A and B."""
    wa, ha, pa, da = decode(a)
    wb, hb, pb, db = decode(b)
    if (wa, ha) != (wb, hb):
        return 1.0
    channels = min(pa, pb, 3)
    total = differ = 0
    for y in range(0, ha, step):
        for x in range(0, wa, step):
            ia, ib = (y * wa + x) * pa, (y * wb + x) * pb
            total += 1
            if any(abs(da[ia + c] - db[ib + c]) > TOLERANCE for c in range(channels)):
                differ += 1
    return differ / total if total else 0.0
