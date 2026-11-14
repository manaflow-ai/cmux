#!/usr/bin/env python3
"""Derive loss/IDR/bitrate/PSNR observations from rd's existing raw artifacts."""

from __future__ import annotations

import json
import math
import struct
import sys
import zlib
from pathlib import Path


def read_ppm(path: Path):
    data = path.read_bytes()
    if not data.startswith(b"P6"):
        return None
    pos = 2
    fields = []
    while len(fields) < 3:
        while pos < len(data) and data[pos] in b" \t\r\n":
            pos += 1
        if pos < len(data) and data[pos] == 35:
            pos = data.find(b"\n", pos) + 1
            continue
        end = pos
        while end < len(data) and data[end] not in b" \t\r\n":
            end += 1
        fields.append(int(data[pos:end]))
        pos = end
    width, height, maximum = fields
    if maximum != 255:
        return None
    while pos < len(data) and data[pos] in b" \t\r\n":
        pos += 1
    pixels = data[pos:pos + width * height * 3]
    return width, height, pixels if len(pixels) == width * height * 3 else None


def paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else b if pb <= pc else c


def read_png(path: Path):
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return None
    pos, chunks, width, height, color, bit_depth = 8, [], None, None, None, None
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += length + 12
        if kind == b"IHDR":
            width, height, bit_depth, color = struct.unpack(">IIBB", body[:10])
            if bit_depth != 8 or color not in (2, 6) or body[10:13] != b"\x00\x00\x00":
                return None
        elif kind == b"IDAT":
            chunks.append(body)
        elif kind == b"IEND":
            break
    if not width or not height:
        return None
    raw = zlib.decompress(b"".join(chunks))
    channels = 3 if color == 2 else 4
    stride = width * channels
    rows, cursor, prior = [], 0, bytes(stride)
    for _ in range(height):
        filt, row = raw[cursor], bytearray(raw[cursor + 1:cursor + 1 + stride])
        cursor += stride + 1
        for i, value in enumerate(row):
            left = row[i - channels] if i >= channels else 0
            up = prior[i]
            upper_left = prior[i - channels] if i >= channels else 0
            if filt == 1:
                row[i] = (value + left) & 255
            elif filt == 2:
                row[i] = (value + up) & 255
            elif filt == 3:
                row[i] = (value + ((left + up) // 2)) & 255
            elif filt == 4:
                row[i] = (value + paeth(left, up, upper_left)) & 255
            elif filt != 0:
                return None
        rows.append(bytes(row))
        prior = row
    rgb = b"".join(row if channels == 3 else b"".join(row[i:i + 3] for i in range(0, len(row), 4)) for row in rows)
    return width, height, rgb


def psnr(source: Path, viewer: Path):
    a, b = read_png(source), read_ppm(viewer)
    if not a or not b or a[:2] != b[:2] or a[2] is None or b[2] is None:
        return None
    mse = sum((x - y) ** 2 for x, y in zip(a[2], b[2])) / len(a[2])
    return None if mse == 0 else round(10 * math.log10((255 * 255) / mse), 3)


def psnr_observation(source: Path, viewer: Path):
    if not source.is_file() or not viewer.is_file():
        return None, "missing image"
    a, b = read_png(source), read_ppm(viewer)
    if not a or not b:
        return None, "unsupported image"
    if a[:2] != b[:2] or a[2] is None or b[2] is None:
        return None, "unpaired dimensions or pixels"
    value = psnr(source, viewer)
    return value, "exact match" if value is None else "paired"


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def main(argv: list[str]) -> int:
    raw_path, out_path, timing_path, source_path, viewer_path = map(Path, argv[1:6])
    result = json.loads(out_path.read_text())
    raw_obj = json.loads(raw_path.read_text()) if raw_path.exists() else {}
    raw_lines = []
    if timing_path.exists():
        for line in timing_path.read_text().splitlines():
            if not line.strip():
                continue
            try:
                raw_lines.append(json.loads(line))
            except ValueError:
                pass
    attempts = len(raw_lines) if timing_path.exists() else None
    series = raw_obj.get("series")
    raw = raw_obj
    if not isinstance(series, list):
        series = []
    latest = next((row.get("host_stats") for row in reversed(series) if isinstance(row.get("host_stats"), dict)), None)
    latest = raw.get("host_stats") or raw.get("host_stats_last") or latest or {}
    frames = number(latest.get("frames"))
    if frames is None:
        values = [number(row.get("frames")) for row in series]
        frames = sum(values) if values and all(v is not None for v in values) else None
    idrs = number(latest.get("keyframes"))
    if idrs is None:
        idr_values = [f.get("idr") or f.get("is_idr") or f.get("keyframe") for f in raw_lines]
        idrs = sum(bool(v) for v in idr_values) if any(v is not None for v in idr_values) else None
    duration_values = [number(row.get("duration_ms")) for row in series]
    duration_ms = sum(duration_values) if duration_values and all(v is not None for v in duration_values) else number(raw.get("duration_ms"))
    byte_values = [number(row.get("bytes")) for row in series]
    bytes_total = sum(byte_values) if byte_values and all(v is not None for v in byte_values) else number(raw.get("bytes"))
    psnr_db, psnr_status = psnr_observation(source_path, viewer_path)
    skips = attempts - frames if attempts is not None and frames is not None and attempts >= frames else None
    extra = result.setdefault("extra", {})
    extra["netem_metrics"] = {
        "attempts": attempts,
        "frames": frames,
        "skips": skips,
        "idrs": idrs,
        "p_frames": frames - idrs if frames is not None and idrs is not None and frames >= idrs else None,
        "bytes": bytes_total,
        "bitrate_bps": round(bytes_total * 8 * 1000 / duration_ms, 2) if bytes_total is not None and duration_ms > 0 else None,
        "on_time_fps": round(frames * 1000 / duration_ms, 3) if frames is not None and duration_ms > 0 else None,
        "psnr_db": psnr_db,
        "psnr_status": psnr_status,
        "idr_count_source": "host_stats.keyframes" if number(latest.get("keyframes")) is not None else "timing_records" if idrs is not None else None,
        "psnr_source": "paired host PNG and viewer PPM" if psnr_status in ("paired", "exact match") else None,
    }
    out_path.write_text(json.dumps(result))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 6:
        raise SystemExit("usage: rd-metrics.py RAW OUT TIMING SOURCE_PNG VIEWER_PPM")
    raise SystemExit(main(sys.argv))
