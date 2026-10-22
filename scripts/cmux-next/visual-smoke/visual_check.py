#!/usr/bin/env python3
"""The nightly-next visual smoke's judge: is each screenshot of the signed app
visibly broken?

drive.py captures the app's window in three scenes (home: the sidebar and the
Home composer; composer: a new agent chat; transcript: an agent chat with one
answered turn). This script checks each capture against scenes.json, which is
the reviewed source of truth for what a scene must show:

- structure, with no reference image: the window is at least the minimum size,
  is not blank or one flat tone, is not opaque black, and every named region
  (the sidebar column, the main area, the composer band) holds drawn content
  (edge density: the share of pixels that differ from a neighbour by a visible
  step, measured on a downscaled grayscale copy, so text and controls count and
  a flat or empty region does not);
- layout, when references/<scene>.png exists: SSIM of a 32x20 grayscale copy of
  the capture against the reference. At that size text is gray mass, so other
  text in the same layout scores about 0.97 and the same window showing another
  scene about 0.3-0.7; an empty pane or a large layout shift fails it.

Pure standard library (its own PNG reader), so it runs on the macOS runner and
in the Linux test lane. On macOS a large capture is first shrunk with `sips`.

  visual_check.py --scenes scenes.json --shots DIR [--references DIR] [--report report.json]

Writes report.json, a Markdown table on stdout, and <scene>-diff.png beside each
capture that has a reference. Exits 1 when any scene fails or is missing.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
WORK_SIDE = 640  # longest side the structural metrics are measured at
GRID = (32, 20)  # the reference comparison's grid (width, height): coarse, so text is gray mass and panels count
EDGE_STEP = 20  # a neighbour difference (0-255 gray) that counts as an edge
DARK_LEVEL = 24  # gray below this is "black"


class Gray:
    """An 8-bit grayscale image, row-major."""

    def __init__(self, width, height, pixels):
        self.width, self.height, self.pixels = width, height, pixels

    def at(self, x, y):
        return self.pixels[y * self.width + x]


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def read_png(path):
    """Decode a non-interlaced 8- or 16-bit gray, gray+alpha, RGB or RGBA PNG to Gray.
    Alpha is composited onto white, so a window that drew nothing reads as blank."""
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError(f"{path}: not a PNG")
    pos, idat, header = len(PNG_SIGNATURE), [], None
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
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color)
    if channels is None or depth not in (8, 16) or interlace:
        raise ValueError(f"{path}: unsupported PNG (color type {color}, depth {depth}, interlace {interlace})")
    raw = zlib.decompress(b"".join(idat))
    sample = depth // 8
    bpp = channels * sample
    stride = width * bpp
    prev = bytearray(stride)
    out = bytearray(width * height)
    pos = 0
    for y in range(height):
        kind = raw[pos]
        row = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if kind == 1:
            for i in range(bpp, stride):
                row[i] = (row[i] + row[i - bpp]) & 0xFF
        elif kind == 2:
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif kind == 3:
            for i in range(stride):
                row[i] = (row[i] + ((row[i - bpp] if i >= bpp else 0) + prev[i]) // 2) & 0xFF
        elif kind == 4:
            for i in range(stride):
                row[i] = (row[i] + _paeth(row[i - bpp] if i >= bpp else 0, prev[i], prev[i - bpp] if i >= bpp else 0)) & 0xFF
        elif kind != 0:
            raise ValueError(f"{path}: bad filter {kind} on row {y}")
        prev = row
        base = y * width
        for x in range(width):
            px = row[x * bpp:(x + 1) * bpp:sample]  # the high byte of each channel
            if channels <= 2:
                luma, alpha = px[0], (px[1] if channels == 2 else 255)
            else:
                luma, alpha = (299 * px[0] + 587 * px[1] + 114 * px[2]) // 1000, (px[3] if channels == 4 else 255)
            out[base + x] = (luma * alpha + 255 * (255 - alpha)) // 255
    return Gray(width, height, out)


def write_png(path, image):
    """Write a Gray as an 8-bit grayscale PNG."""
    rows = b"".join(b"\x00" + bytes(image.pixels[y * image.width:(y + 1) * image.width]) for y in range(image.height))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(PNG_SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", image.width, image.height, 8, 0, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if not head.startswith(PNG_SIGNATURE):
        raise ValueError(f"{path}: not a PNG")
    return struct.unpack(">II", head[16:24])


def load(path, max_side=WORK_SIDE):
    """The capture as Gray, its longest side at most about max_side. A large PNG is shrunk with
    macOS `sips` first when it is there (the pure-Python decoder is slow on a full Retina window)."""
    width, height = png_size(path)
    if max(width, height) > max_side and shutil.which("sips"):
        with tempfile.TemporaryDirectory() as tmp:
            small = os.path.join(tmp, "small.png")
            subprocess.run(["sips", "-Z", str(max_side), path, "--out", small], check=True, capture_output=True)
            image = read_png(small)
    else:
        image = read_png(path)
    return resize(image, *fit(image.width, image.height, max_side)) if max(image.width, image.height) > max_side else image


def fit(width, height, side):
    scale = side / max(width, height)
    return max(1, round(width * scale)), max(1, round(height * scale))


def resize(image, width, height):
    """Box-average resize (each output pixel is the mean of the source pixels it covers)."""
    out = bytearray(width * height)
    for oy in range(height):
        y0 = oy * image.height // height
        y1 = max(y0 + 1, (oy + 1) * image.height // height)
        for ox in range(width):
            x0 = ox * image.width // width
            x1 = max(x0 + 1, (ox + 1) * image.width // width)
            total = 0
            for y in range(y0, y1):
                base = y * image.width
                total += sum(image.pixels[base + x0:base + x1])
            out[oy * width + ox] = total // ((y1 - y0) * (x1 - x0))
    return Gray(width, height, out)


def region_box(image, region):
    """[x0, y0, x1, y1] fractions of the image to a pixel box (at least 2x2)."""
    x0, y0, x1, y1 = region
    left, top = int(x0 * image.width), int(y0 * image.height)
    right, bottom = max(left + 2, int(x1 * image.width)), max(top + 2, int(y1 * image.height))
    return left, top, min(right, image.width), min(bottom, image.height)


def metrics(image, region=(0, 0, 1, 1)):
    """edge: share of pixels with a visible step to the right or below neighbour;
    dark: share of near-black pixels; flat: share of the most common gray band (32 bands);
    mean: mean gray."""
    left, top, right, bottom = region_box(image, region)
    w, px = image.width, image.pixels
    edges = dark = total = 0
    bands = [0] * 32
    for y in range(top, bottom):
        base = y * w
        below = base + w if y + 1 < bottom else None
        for x in range(left, right):
            v = px[base + x]
            total += v
            bands[v >> 3] += 1
            if v < DARK_LEVEL:
                dark += 1
            if (x + 1 < right and abs(v - px[base + x + 1]) >= EDGE_STEP) or (below is not None and abs(v - px[below + x]) >= EDGE_STEP):
                edges += 1
    count = (right - left) * (bottom - top)
    return {"edge": round(edges / count, 5), "dark": round(dark / count, 5), "flat": round(max(bands) / count, 5),
            "mean": round(total / count, 1)}


def ssim(a, b):
    """Mean SSIM over 8x8 windows (stride 4) of two same-size Gray images."""
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    scores = []
    for top in range(0, a.height - 7, 4):
        for left in range(0, a.width - 7, 4):
            xs = [a.pixels[(top + j) * a.width + left + i] for j in range(8) for i in range(8)]
            ys = [b.pixels[(top + j) * b.width + left + i] for j in range(8) for i in range(8)]
            mx, my = sum(xs) / 64, sum(ys) / 64
            vx = sum((x - mx) ** 2 for x in xs) / 63
            vy = sum((y - my) ** 2 for y in ys) / 63
            cov = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / 63
            scores.append(((2 * mx * my + c1) * (2 * cov + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2)))
    return round(sum(scores) / len(scores), 4) if scores else 1.0


def diff_image(a, b, scale=12):
    """|a - b| on the grid, scaled up and stretched so differences are easy to see."""
    width, height = a.width * scale, a.height * scale
    out = bytearray(width * height)
    for y in range(height):
        for x in range(width):
            i = (y // scale) * a.width + x // scale
            out[y * width + x] = min(255, 3 * abs(a.pixels[i] - b.pixels[i]))
    return Gray(width, height, out)


def check_scene(name, spec, defaults, shot, reference=None, diff_path=None):
    """One scene's result: {"ok", "failures": [...], "metrics": {...}}."""
    limits = {**defaults, **{k: v for k, v in spec.items() if k not in ("what", "regions")}}
    result = {"scene": name, "what": spec.get("what", ""), "failures": [], "metrics": {}}
    fail = result["failures"].append
    if not os.path.exists(shot):
        fail("no capture (the driver did not reach this scene)")
        result["ok"] = False
        return result
    width, height = png_size(shot)
    result["size"] = [width, height]
    min_w, min_h = limits["min_size"]
    if width < min_w or height < min_h:
        fail(f"capture is {width}x{height}, smaller than {min_w}x{min_h} (the window is missing or collapsed)")
    image = load(shot)
    whole = metrics(image)
    result["metrics"]["window"] = whole
    if whole["edge"] < limits["min_edge"]:
        fail(f"window is blank: edge density {whole['edge']} < {limits['min_edge']}")
    if whole["dark"] > limits["max_dark"]:
        fail(f"window is opaque black: {whole['dark']:.0%} of it is near-black (limit {limits['max_dark']:.0%})")
    if whole["flat"] > limits["max_flat"]:
        fail(f"window is one flat tone: {whole['flat']:.0%} of it is a single gray band (limit {limits['max_flat']:.0%})")
    for region_name, region in (spec.get("regions") or {}).items():
        found = metrics(image, region["box"])
        result["metrics"][region_name] = found
        need = region.get("min_edge", limits["min_region_edge"])
        if found["edge"] < need:
            fail(f"{region_name} is empty: edge density {found['edge']} < {need} in box {region['box']}"
                 + (f" ({region['what']})" if region.get("what") else ""))
    if reference:
        ref = load(reference)
        a, b = resize(image, *GRID), resize(ref, *GRID)
        score = ssim(a, b)
        result["metrics"]["reference_ssim"] = score
        result["reference"] = os.path.basename(reference)
        if diff_path:
            write_png(diff_path, diff_image(a, b))
            result["diff"] = os.path.basename(diff_path)
        if score < limits["min_ssim"]:
            fail(f"layout differs from references/{os.path.basename(reference)}: SSIM {score} < {limits['min_ssim']}")
    result["ok"] = not result["failures"]
    return result


def crop(image, box):
    """The [x0, y0, x1, y1] fraction box of image."""
    left, top, right, bottom = region_box(image, box)
    rows = [image.pixels[y * image.width + left:y * image.width + right] for y in range(top, bottom)]
    return Gray(right - left, bottom - top, bytearray(b"".join(rows)))


def check_distinct(config, shots, results):
    """Fail a scene whose capture matches another scene's (`distinct_from` in scenes.json):
    the driver never reached it and captured the previous scene again. The two captures'
    distinct_box (right of the sidebar) are compared on the reference grid; SSIM at or above
    max_scene_ssim is a match."""
    grids = {}
    box = config["defaults"].get("distinct_box", [0, 0, 1, 1])

    def grid(name):
        if name not in grids:
            path = os.path.join(shots, f"{name}.png")
            grids[name] = resize(crop(load(path), box), *GRID) if os.path.exists(path) else None
        return grids[name]
    for name, spec in config["scenes"].items():
        result = results[name]
        limit = spec.get("max_scene_ssim", config["defaults"].get("max_scene_ssim", 0.9))
        for other in spec.get("distinct_from", []):
            if other not in config["scenes"]:
                raise ValueError(f"scene {name}: distinct_from names unknown scene {other}")
            a, b = grid(name), grid(other)
            if a is None or b is None:
                continue  # a missing capture already fails its own scene
            score = ssim(a, b)
            result["metrics"].setdefault("scene_ssim", {})[other] = score
            if score >= limit:
                result["failures"].append(f"looks the same as the {other} scene: SSIM {score} >= {limit}"
                                          " (the driver did not reach this scene)")
        result["ok"] = not result["failures"]


def run(scenes_path, shots, references=None, report_path=None):
    with open(scenes_path) as f:
        config = json.load(f)
    defaults = config["defaults"]
    results = []
    for name, spec in config["scenes"].items():
        shot = os.path.join(shots, f"{name}.png")
        reference = os.path.join(references, f"{name}.png") if references else None
        if reference and not os.path.exists(reference):
            reference = None
        results.append(check_scene(name, spec, defaults, shot, reference, os.path.join(shots, f"{name}-diff.png")))
    check_distinct(config, shots, {r["scene"]: r for r in results})
    report = {"ok": all(r["ok"] for r in results), "scenes": results}
    if report_path:
        with open(report_path, "w") as f:
            json.dump(report, f, indent=1)
    return report


def markdown(report):
    lines = ["| Scene | Result | Window edge | Regions | Reference SSIM |", "| --- | --- | --- | --- | --- |"]
    for r in report["scenes"]:
        m = r["metrics"]
        regions = ", ".join(f"{k} {v['edge']}" for k, v in m.items() if k not in ("window", "reference_ssim", "scene_ssim"))
        lines.append(f"| {r['scene']} | {'ok' if r['ok'] else 'FAIL'} | {m.get('window', {}).get('edge', '-')} | "
                     f"{regions or '-'} | {m.get('reference_ssim', 'no reference')} |")
    for r in report["scenes"]:
        for failure in r["failures"]:
            lines.append(f"- **{r['scene']}**: {failure}")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--scenes", required=True)
    parser.add_argument("--shots", required=True)
    parser.add_argument("--references")
    parser.add_argument("--report")
    args = parser.parse_args(argv)
    report = run(args.scenes, args.shots, args.references, args.report)
    print(markdown(report))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
