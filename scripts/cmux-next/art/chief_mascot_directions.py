#!/usr/bin/env python3
"""Derive the animated Chief characters' direction rows: looking left, right, up and down while
thinking, and leaning toward a drag.

Usage: python3 scripts/cmux-next/art/chief_mascot_directions.py [--check] [--contact OUT.png]

Each set's six state rows (`cmux-avatar/1`, webviews `avatars/sets/<id>/sheet.png`, rows 0 to 5)
were drawn by hand in #25213 and are the source; this script never changes them. From them it
draws eight rows under them, in this order, and names them in the manifest's `directions`:

- look left, right, up, down (rows 6 to 9): the thinking row, frame by frame, with the face (eyes,
  mouth and cheeks) slid 1 px toward the direction. The pixels behind the face close up with the
  colour next to it, so the outline and the thought bubble never move.
- drag left, right, up, down (rows 10 to 13): the idle row, looking the same way, with the body
  sheared toward the drag (the top leads by 3 px, the feet stay where they stand) for left and
  right, stretched 2 px up for up, and squashed 2 px for down.

The gallery compares these picks with the alternatives (`VARIANTS`), each a whole sheet in webviews
`avatars/variants/<id>-<variant>.png`: the eyes alone sliding, a blink as the look turns, the body
offset in two steps, and a squash and stretch. `chief_mascot_animated.py` writes everything this
makes (and copies the sheets into CmuxNextFloating's Resources); `--check` exits 1 when a written
file differs. `--contact` also draws the source and direction rows of every set and variant 8x on
one PNG, to look at. zlib only.
"""
import json
import struct
import sys
import zlib

from chief_mascot_series2 import ROOT

AVATARS = ROOT / "webviews/src/agent-session/acpmux/avatars"
SETS = AVATARS / "sets"
VARIANT_DIR = AVATARS / "variants"
NAMES = ("mochi", "captain", "sprout", "bolt")
DIRECTIONS = ("left", "right", "up", "down")
STEP = {"left": (-1, 0), "right": (1, 0), "up": (0, -1), "down": (0, 1)}
SOURCE_ROWS = 6
LOOK_ROW, DRAG_ROW = 6, 10
DRAG_FPS = 8

# Each set's face, on the first frame of its idle row (`idle`) and of its thinking row (`thinking`):
# the eyes' box and the face's box (eyes, mouth and cheeks), (x0, y0, x1, y1) inclusive, and the
# first row of its feet (`ground`), which a drag never moves. Later frames find their own offset.
FACES = {
    "mochi": {"idle": ((17, 18, 25, 20), (15, 18, 25, 22)), "thinking": ((17, 18, 25, 19), (15, 18, 25, 22)), "ground": 28},
    "captain": {"idle": ((13, 17, 19, 19), (11, 17, 21, 20)), "thinking": ((14, 16, 20, 17), (12, 16, 22, 20)), "ground": 27},
    "sprout": {"idle": ((21, 16, 22, 17), (21, 16, 23, 21)), "thinking": ((21, 16, 22, 17), (21, 16, 23, 21)), "ground": 25},
    "bolt": {"idle": ((14, 13, 21, 14), (14, 13, 21, 20)), "thinking": ((14, 12, 21, 13), (14, 12, 21, 20)), "ground": 23},
}

# The shipped look and lean, then the alternatives the gallery shows beside them.
SHIPPED = ("face", "shear")
VARIANTS = {"look-eyes": ("eyes", "shear"), "look-blink": ("blink", "shear"),
            "drag-offset": ("face", "offset"), "drag-squash": ("face", "squash")}

CLEAR = (0, 0, 0, 0)


# PNG in and out ---------------------------------------------------------------------------------

def read_png(data):
    """An 8-bit RGBA or palette PNG: (width, height, rows of RGBA tuples, transparent ones zeroed)."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, palette, alpha = 8, b"", [], b""
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and colour in (3, 6) and interlace == 0, "not 8-bit RGBA or palette"
        elif kind == b"PLTE":
            palette = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif kind == b"tRNS":
            alpha = body
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    step = 4 if colour == 6 else 1
    raw, stride, rows = zlib.decompress(idat), width * step, []
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
        row = []
        for x in range(width):
            if colour == 6:
                pixel = tuple(line[x * 4:x * 4 + 4])
            else:
                k = line[x]
                pixel = palette[k] + (alpha[k] if k < len(alpha) else 255,)
            row.append(pixel if pixel[3] else CLEAR)
        rows.append(row)
    return width, height, rows


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


def png_indexed(rows):
    """A palette PNG of `rows` (as the hand-drawn sheets are: a few KB), colours in first-seen order."""
    colours = {CLEAR: 0}
    for row in rows:
        for pixel in row:
            colours.setdefault(pixel, len(colours))
    assert len(colours) <= 256, "over 256 colours"
    height, width = len(rows), len(rows[0])
    data = bytearray()
    for row in rows:
        data.append(0)
        data += bytes(colours[pixel] for pixel in row)
    palette = b"".join(bytes(c[:3]) for c in colours)
    alpha = bytes(c[3] for c in colours)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 3, 0, 0, 0))
            + chunk(b"PLTE", palette) + chunk(b"tRNS", alpha)
            + chunk(b"IDAT", zlib.compress(bytes(data), 9)) + chunk(b"IEND", b""))


def png_rgba(rows):
    data = bytearray()
    for row in rows:
        data.append(0)
        for pixel in row:
            data += bytes(pixel)
    height, width = len(rows), len(rows[0])
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(data), 9)) + chunk(b"IEND", b""))


# Frames -----------------------------------------------------------------------------------------

def cut(rows, size, row, index):
    return [line[index * size:(index + 1) * size] for line in rows[row * size:(row + 1) * size]]


def get(frame, x, y):
    return frame[y][x] if 0 <= y < len(frame) and 0 <= x < len(frame[0]) else CLEAR


def offset_of(frame, reference, box):
    """Where `frame` drew the part of `reference` around `box` (a bob of a pixel or two): the shift
    with the most matching opaque pixels, the smallest first on a tie."""
    x0, y0, x1, y1 = box
    best, found = -1, (0, 0)
    for dx, dy in sorted(((dx, dy) for dx in range(-2, 3) for dy in range(-2, 3)), key=lambda d: (abs(d[0]) + abs(d[1]), d)):
        score = sum(1 for y in range(y0 - 2, y1 + 3) for x in range(x0 - 2, x1 + 3)
                    if reference[y][x] != CLEAR and get(frame, x + dx, y + dy) == reference[y][x])
        if score > best:
            best, found = score, (dx, dy)
    return found


def moved(box, offset):
    x0, y0, x1, y1 = box
    return (x0 + offset[0], y0 + offset[1], x1 + offset[0], y1 + offset[1])


def slide(frame, box, step):
    """`box`'s pixels moved one step; the pixels it leaves take the colour just behind it."""
    dx, dy = step
    x0, y0, x1, y1 = box
    out = [list(line) for line in frame]
    for y in range(min(y0, y0 + dy), max(y1, y1 + dy) + 1):
        for x in range(min(x0, x0 + dx), max(x1, x1 + dx) + 1):
            if 0 <= x < len(out[0]) and 0 <= y < len(out):
                out[y][x] = get(frame, x - dx, y - dy)
    return out


def closed(frame, box):
    """The eyes in `box` shut: each column keeps its lowest eye pixel; the rest take the box's skin."""
    x0, y0, x1, y1 = box
    counts = {}
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            counts[frame[y][x]] = counts.get(frame[y][x], 0) + 1
    skin = max(sorted(counts), key=lambda c: counts[c])
    out = [list(line) for line in frame]
    for x in range(x0, x1 + 1):
        eye = [y for y in range(y0, y1 + 1) if frame[y][x] != skin]
        if not eye:
            continue
        darkest = min((frame[y][x] for y in eye), key=lambda c: sum(c[:3]))
        for y in eye:
            out[y][x] = skin
        out[max(eye)][x] = darkest
    return out


def look(frame, boxes, offset, direction, style, index):
    """`frame` looking `direction`: the face slid (`face`), the eyes alone (`eyes`), or the face
    slid with its first frame blinking (`blink`)."""
    eyes, face = (moved(box, offset) for box in boxes)
    if style == "eyes":
        return slide(frame, eyes, STEP[direction])
    turned = slide(frame, face, STEP[direction])
    if style == "blink" and index == 0:
        return closed(turned, moved(eyes, STEP[direction]))
    return turned


def bounds(frame):
    ys = [y for y, line in enumerate(frame) if any(p != CLEAR for p in line)]
    return ys[0], ys[-1]


def lean(frame, ground, direction, style):
    """`frame` pulled `direction`: the rows above `ground` (the feet) give way, the feet stay.
    `shear`: left and right shear (the top leads by 3 px), up stretches 2 px, down squashes 2 px.
    `offset`: the body moves whole, 2 px at the top and 1 px at the waist (up 2 px, down 1 px).
    `squash`: the body stretches along the pull and narrows across it."""
    size = len(frame)
    top, _ = bounds(frame)
    ground = max(ground, top + 4)
    sign = -1 if direction in ("left", "up") else 1
    if direction in ("left", "right"):
        if style == "squash":
            return vertical(widen(frame, ground, sign), top, ground, 1)
        out = [list(line) for line in frame]
        for y in range(ground):
            if style == "shear":
                shift = round(3 * (ground - y) / (ground - top))
            else:
                shift = 2 if y < (top + ground) // 2 else 1
            out[y] = [get(frame, x - sign * shift, y) for x in range(size)]
        return out
    if style == "offset":
        out = [list(line) for line in frame]
        lift = 2 if direction == "up" else -1
        for y in range(ground):
            source = y + lift
            # Lifted, the legs (the row over the feet) grow to fill the gap.
            out[y] = list(frame[min(source, ground - 1)]) if source >= 0 else [CLEAR] * size
        return out
    if style == "squash":
        out = vertical(frame, top, ground, 3 * sign)
        left, right = edges(frame)
        middle, factor = (left + right) / 2, (1.15 if direction == "down" else 0.88)
        for y in range(ground):
            out[y] = [get(out, round(middle + (x - middle) / factor), y) for x in range(size)]
        return out
    return vertical(frame, top, ground, 2 * sign)


def widen(frame, ground, sign):
    """The rows above `ground` 2 px wider toward `sign` (the trailing side stays)."""
    left, right = edges(frame)
    span = right - left
    out = [list(line) for line in frame]
    for y in range(ground):
        for x in range(len(frame[0])):
            if sign > 0 and left <= x <= right + 2:
                out[y][x] = get(frame, left + round((x - left) * span / (span + 2)), y)
            elif sign < 0 and left - 2 <= x <= right:
                out[y][x] = get(frame, right - round((right - x) * span / (span + 2)), y)
    return out


def edges(frame):
    xs = [x for line in frame for x, p in enumerate(line) if p != CLEAR]
    return min(xs), max(xs)


def vertical(frame, top, ground, reach):
    """The rows from `top` to `ground` scaled so the top moves by `reach` (negative: up); feet stay."""
    size = len(frame)
    out = [list(line) for line in frame]
    new_top = top + reach
    for y in range(size):
        if y >= ground:
            continue
        if y < new_top:
            out[y] = [CLEAR] * size
            continue
        source = ground - round((ground - y) * (ground - top) / (ground - new_top))
        out[y] = list(frame[source]) if 0 <= source < size else [CLEAR] * size
    return out


# Sheets -----------------------------------------------------------------------------------------

def build(name, style=SHIPPED):
    """The set's sheet with its direction rows (palette PNG bytes) and its manifest text."""
    folder = SETS / name
    manifest = json.loads((folder / "avatar.json").read_text())
    size = manifest["frame"]["width"]
    width, _, rows = read_png((folder / "sheet.png").read_bytes())
    states = manifest["states"]
    source = rows[:SOURCE_ROWS * size]
    width = max(width, max(spec["frames"] for spec in states.values()) * size)
    source = [line + [CLEAR] * (width - len(line)) for line in source]
    look_style, drag_style = style
    face = FACES[name]
    new_rows = []
    for kind, state, base in (("look", "thinking", LOOK_ROW), ("drag", "idle", DRAG_ROW)):
        spec = states[state]
        boxes = face[state]
        reference = cut(source, size, spec["row"], 0)
        for direction in DIRECTIONS:
            band = [[CLEAR] * width for _ in range(size)]
            for index in range(spec["frames"]):
                frame = cut(source, size, spec["row"], index)
                offset = offset_of(frame, reference, boxes[1])
                if kind == "look":
                    drawn = look(frame, boxes, offset, direction, look_style, index)
                else:
                    turned = look(frame, boxes, offset, direction, "face", 1)
                    drawn = lean(turned, face["ground"] + offset[1], direction, drag_style)
                for y in range(size):
                    band[y][index * size:(index + 1) * size] = drawn[y]
            new_rows += band
    return png_indexed(source + new_rows), manifest_text(manifest)


def manifest_text(manifest):
    """avatar.json with `directions` (rows 6 to 13), one state or direction per line as the sets keep it."""
    states = manifest["states"]
    thinking, idle = states["thinking"], states["idle"]
    look_spec = {"frames": thinking["frames"], "fps": thinking.get("fps", manifest["fps"])}
    directions = {
        "look": {d: {"row": LOOK_ROW + i, **look_spec} for i, d in enumerate(DIRECTIONS)},
        "drag": {d: {"row": DRAG_ROW + i, "frames": idle["frames"], "fps": DRAG_FPS} for i, d in enumerate(DIRECTIONS)},
    }

    def inline(value):
        return json.dumps(value, separators=(", ", ": ")).replace("{", "{ ").replace("}", " }")

    head = {k: v for k, v in manifest.items() if k not in ("states", "directions")}
    lines = ["{"]
    for key, value in head.items():
        lines.append(f'  "{key}": {inline(value)},')
    lines.append('  "states": {')
    lines.append(",\n".join(f'    "{k}": {inline(v)}' for k, v in states.items()))
    lines.append("  },")
    lines.append('  "directions": {')
    groups = []
    for group, specs in directions.items():
        body = ",\n".join(f'      "{k}": {inline(v)}' for k, v in specs.items())
        groups.append(f'    "{group}": {{\n{body}\n    }}')
    lines.append(",\n".join(groups))
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def outputs():
    """(path, bytes) for every file this script owns: each set's sheet and manifest, then the variants."""
    for name in NAMES:
        sheet, text = build(name)
        yield SETS / name / "sheet.png", sheet
        yield SETS / name / "avatar.json", text.encode()
    for name in NAMES:
        for variant, style in VARIANTS.items():
            yield VARIANT_DIR / f"{name}-{variant}.png", build(name, style)[0]


def contact(path):
    """8x, one line per set: thinking, looking left, right, up and down, then idle and the drag
    left, right, up and down (each row's first frame); then Mochi's line from each variant sheet."""
    scale, size, gap = 8, 32, 8
    lines = []
    for name in NAMES:
        lines.append(build(name)[0])
    for style in VARIANTS.values():
        lines.append(build("mochi", style)[0])
    columns = [2, 6, 7, 8, 9, 0, 10, 11, 12, 13]
    cell = size * scale + gap
    width, height = len(columns) * cell + gap, len(lines) * cell + gap
    background = (44, 44, 52, 255)
    canvas = [[background] * width for _ in range(height)]
    for line, data in enumerate(lines):
        _, _, rows = read_png(data)
        for column, row in enumerate(columns):
            frame = cut(rows, size, row, 0)
            for sy, pixels in enumerate(frame):
                for sx, pixel in enumerate(pixels):
                    if pixel == CLEAR:
                        continue
                    for yy in range(scale):
                        target = canvas[gap + line * cell + sy * scale + yy]
                        at = gap + column * cell + sx * scale
                        target[at:at + scale] = [pixel] * scale
    path.write_bytes(png_rgba(canvas))


def main():
    from pathlib import Path
    args = sys.argv[1:]
    if "--contact" in args:
        contact(Path(args[args.index("--contact") + 1]))
        return 0
    check = "--check" in args
    VARIANT_DIR.mkdir(exist_ok=True)
    stale = []
    for target, data in list(outputs()):
        if target.exists() and target.read_bytes() == data:
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
