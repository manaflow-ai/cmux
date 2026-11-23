#!/usr/bin/env python3
"""How much of what is behind a window shows through under a terminal pane, from capture PNGs.

Reads an empty patch of the shot's right-hand pane (x 60-95%, y 62-92% by default; `--box` sets it) and
prints its luma mean, luma standard deviation and widest per-channel spread. A solid theme fill gives
a std near 0; the glass or picture showing through raises it. Run it over a before and an after set of
the same tour (`cmux-ci capture --state scripts/cmux-next/media/tours/terminal-over-glass.json`) so both
numbers come from one harness. Pure standard library (8-bit RGB/RGBA, non-interlaced PNG), so it runs on
Linux: `python3 -I scripts/measure/pane-show-through.py SHOT.png ...` (one tab-separated line per shot).
"""
import argparse
import struct
import sys
import zlib


def decode(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")
    pos, idat, head = 8, [], None
    while pos < len(data):
        length, kind = struct.unpack_from("!I4s", data, pos)
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            head = struct.unpack("!IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        pos += 12 + length
    width, height, depth, color, _, _, interlace = head
    if depth != 8 or color not in (2, 6) or interlace:
        raise ValueError(f"{path}: needs 8-bit RGB or RGBA, non-interlaced (depth {depth}, color {color})")
    step = 3 if color == 2 else 4
    raw = zlib.decompress(b"".join(idat))
    stride = width * step
    rows, prev = [], bytearray(stride)
    for y in range(height):
        kind = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - step] if i >= step else 0
            b = prev[i]
            c = prev[i - step] if i >= step else 0
            if kind == 1:
                line[i] = (line[i] + a) & 255
            elif kind == 2:
                line[i] = (line[i] + b) & 255
            elif kind == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif kind == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return width, height, step, rows


def measure(path, box):
    width, height, step, rows = decode(path)
    x0, y0, x1, y1 = int(width * box[0]), int(height * box[1]), int(width * box[2]), int(height * box[3])
    pixels = [(rows[y][x * step], rows[y][x * step + 1], rows[y][x * step + 2])
              for y in range(y0, y1) for x in range(x0, x1)]
    luma = [0.2126 * r + 0.7152 * g + 0.0722 * b for r, g, b in pixels]
    mean = sum(luma) / len(luma)
    std = (sum((value - mean) ** 2 for value in luma) / len(luma)) ** 0.5
    spread = max(max(p[i] for p in pixels) - min(p[i] for p in pixels) for i in range(3))
    return mean, std, spread


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("shots", nargs="+")
    parser.add_argument("--box", default="0.60,0.62,0.95,0.92", help="x0,y0,x1,y1 as fractions of the shot")
    opts = parser.parse_args()
    box = [float(v) for v in opts.box.split(",")]
    for path in opts.shots:
        try:
            mean, std, spread = measure(path, box)
        except (OSError, ValueError) as error:
            print(f"{path}\terror={error}", file=sys.stderr)
            continue
        print(f"{path}\tluma_mean={mean:.1f}\tluma_std={std:.2f}\tspread={spread}")


if __name__ == "__main__":
    main()
